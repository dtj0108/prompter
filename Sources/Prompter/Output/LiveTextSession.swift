import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct LiveTextSnapshot: Equatable {
    var text: String
    var selection: NSRange
}

/// Only targets that can read and replace an exact text range may type live.
/// Returning nil means focus, security, or accessibility changed.
protocol LiveTextTarget: AnyObject {
    func snapshot() -> LiveTextSnapshot?
    func replace(_ range: NSRange, with text: String, expecting: LiveTextSnapshot) -> Bool
}

/// Owns just the dictation's range. All offsets are UTF-16, as required by AX.
/// Used on the main thread; unsupported fields retain normal end-of-dictation paste.
final class LiveTextSession {
    private let target: LiveTextTarget
    private var expected: LiveTextSnapshot
    private var ownedRange: NSRange
    private var pendingText: String?
    private var updateWork: DispatchWorkItem?
    private var focusTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var inputMonitors: [Any] = []
    private(set) var isSuspended = false
    private(set) var hasWritten = false

    init?(target: LiveTextTarget) {
        guard let snapshot = target.snapshot(),
              Range(snapshot.selection, in: snapshot.text) != nil else { return nil }
        self.target = target
        self.expected = snapshot
        self.ownedRange = snapshot.selection
    }

    static func capture(shortcuts: [HotkeyShortcut]) -> LiveTextSession? {
        guard let target = AccessibilityLiveTextTarget.capture(),
              let session = LiveTextSession(target: target) else { return nil }
        session.startMonitoring(shortcuts: shortcuts)
        return session
    }

    func receive(_ text: String) {
        guard !isSuspended, !text.isEmpty else { return }
        pendingText = text
        guard updateWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateWork = nil
            guard let text = self.pendingText else { return }
            self.pendingText = nil
            _ = self.apply(text)
        }
        updateWork = work
        // Coalesce nearby tokens so we don't select the field on every token.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Validate even if the final transcript matches the preview. A user edit or
    /// focus change must never trigger a second paste or a stale cleanup rewrite.
    func finish(_ text: String) -> Bool {
        updateWork?.cancel()
        updateWork = nil
        pendingText = nil
        defer { stopMonitoring() }
        return apply(text)
    }

    /// Escape/shortcut cancellation keeps any words already inserted.
    func cancel() {
        suspend()
        stopMonitoring()
    }

    func validate() {
        guard !isSuspended else { return }
        if target.snapshot() != expected { suspend() }
    }

    func suspend() {
        isSuspended = true
        updateWork?.cancel()
        updateWork = nil
        pendingText = nil
    }

    @discardableResult
    private func apply(_ text: String) -> Bool {
        guard !isSuspended, target.snapshot() == expected,
              let range = Range(ownedRange, in: expected.text) else {
            suspend()
            return false
        }
        // Until the first write, even identical selected text must collapse to a caret.
        if hasWritten && String(expected.text[range]) == text { return true }
        let nextText = expected.text.replacingCharacters(in: range, with: text)
        let nextRange = NSRange(location: ownedRange.location, length: text.utf16.count)
        let next = LiveTextSnapshot(text: nextText, selection: NSRange(location: NSMaxRange(nextRange), length: 0))
        // An AX failure may still have changed the editor: never fall back to a
        // blind append after attempting the mutation.
        hasWritten = true
        guard target.replace(ownedRange, with: text, expecting: expected),
              target.snapshot() == next else {
            suspend()
            return false
        }
        expected = next
        ownedRange = nextRange
        return true
    }

    static func isControlEvent(_ event: NSEvent, shortcuts: [HotkeyShortcut]) -> Bool {
        shortcuts.contains { shortcut in
            (event.type == .keyDown && shortcut.matchesKeyDown(event))
                || (event.type == .otherMouseDown && shortcut.matchesMouseButton(event))
        }
    }

    private func startMonitoring(shortcuts: [HotkeyShortcut]) {
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.validate() }
        focusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.validate() }
        // Stop before any manual editing/clicking, even if the user returns the
        // cursor to the same position before the next transcript arrives.
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let handler: (NSEvent) -> Void = { [weak self] event in
            if Self.isControlEvent(event, shortcuts: shortcuts) { return }
            self?.suspend()
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            inputMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) { inputMonitors.append(monitor) }
    }

    private func stopMonitoring() {
        focusTimer?.invalidate()
        focusTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        inputMonitors.forEach { NSEvent.removeMonitor($0) }
        inputMonitors.removeAll()
    }

    deinit {
        updateWork?.cancel()
        stopMonitoring()
    }
}

private final class AccessibilityLiveTextTarget: LiveTextTarget {
    let pid: pid_t
    let app: AXUIElement
    let element: AXUIElement

    init(pid: pid_t, app: AXUIElement, element: AXUIElement) {
        self.pid = pid
        self.app = app
        self.element = element
    }

    static func capture() -> AccessibilityLiveTextTarget? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Electron may not expose editable text until accessibility is enabled.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let element = focusedElement(app) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard isSettable(element, kAXSelectedTextRangeAttribute),
              isSettable(element, kAXSelectedTextAttribute) else { return nil }
        let target = AccessibilityLiveTextTarget(pid: front.processIdentifier, app: app, element: element)
        guard target.snapshot() != nil else { return nil }
        return target
    }

    func snapshot() -> LiveTextSnapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focusedElement(app), CFEqual(focused, element),
              string(kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String,
              let value = string(kAXValueAttribute),
              let selection = selectedRange(), Range(selection, in: value) != nil else { return nil }
        return LiveTextSnapshot(text: value, selection: selection)
    }

    func replace(_ range: NSRange, with text: String, expecting expected: LiveTextSnapshot) -> Bool {
        guard snapshot() == expected, setSelection(range) else { return false }
        // Read back selection before replacing. Some web editors expose ranges
        // but don't apply them faithfully (especially across line breaks).
        guard snapshot() == LiveTextSnapshot(text: expected.text, selection: range) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            // No repeated keys, backspaces, or whole-field writes on an uncertain target.
            return false
        }
        // Don't move the caret in an app the user has left, or after another edit.
        guard let changed = snapshot(),
              let swiftRange = Range(range, in: expected.text),
              changed.text == expected.text.replacingCharacters(in: swiftRange, with: text) else { return false }
        return setSelection(NSRange(location: range.location + text.utf16.count, length: 0))
    }

    private func string(_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedRange() -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setSelection(_ range: NSRange) -> Bool {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

#if DEBUG
extension LiveTextSession {
    static func verifyFixture() -> Bool {
        guard let target = AccessibilityLiveTextTarget.capture(),
              let initial = target.snapshot(),
              initial.text == "Live typing test: ORIGINAL :end",
              initial.selection == NSRange(location: 18, length: 8),
              let session = LiveTextSession(target: target) else {
            print("Live insertion fixture unavailable (requires Accessibility and the test field).")
            return false
        }
        guard session.finish("hello"),
              session.finish("Hello world."),
              target.snapshot()?.text == "Live typing test: Hello world. :end" else { return false }
        print("PASS: actual accessibility insertion and final replacement preserve surrounding text")
        session.cancel()
        return true
    }
}
#endif
