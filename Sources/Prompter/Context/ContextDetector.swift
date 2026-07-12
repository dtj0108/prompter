import AppKit
import ApplicationServices
import Combine

struct FrontContext {
    var appName: String
    var bundleId: String
    var pid: pid_t
    var windowTitle: String
    var style: ContextStyle

    static let unknown = FrontContext(
        appName: "",
        bundleId: "",
        pid: 0,
        windowTitle: "",
        style: StyleConfig.default.contexts.last!
    )
}

/// Tracks the last non-Prompter app the user activated. The Style window makes
/// Prompter itself frontmost, so retaining the previous app lets that page offer
/// a useful "style this app" control instead of showing Prompter.
final class ActiveAppMonitor: ObservableObject {
    static let shared = ActiveAppMonitor()

    @Published private(set) var appName = ""
    @Published private(set) var bundleId = ""

    private var activationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        if let app = NSWorkspace.shared.frontmostApplication { note(app) }
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.note(app)
        }
    }

    func note(_ app: NSRunningApplication) {
        let id = app.bundleIdentifier ?? ""
        guard !id.isEmpty, id != Bundle.main.bundleIdentifier else { return }
        appName = app.localizedName ?? id
        bundleId = id
    }
}

enum ContextDetector {

    /// Snapshot the frontmost app + focused window title and resolve which style context applies.
    /// Call this at hotkey-press time, before the HUD appears.
    static func capture() -> FrontContext {
        let style = StyleStore.shared.style
        let fallback = style.contexts.first(where: { $0.id == "other" }) ?? style.contexts.last ?? StyleConfig.default.contexts.last!

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FrontContext(appName: "", bundleId: "", pid: 0, windowTitle: "", style: fallback)
        }
        ActiveAppMonitor.shared.note(app)
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        let title = focusedWindowTitle(pid: app.processIdentifier) ?? ""

        let matched = match(bundleId: bundleId, title: title, contexts: style.contexts) ?? fallback
        return FrontContext(appName: name, bundleId: bundleId, pid: app.processIdentifier, windowTitle: title, style: matched)
    }

    static func match(bundleId: String, title: String, contexts: [ContextStyle]) -> ContextStyle? {
        let lowerBundle = bundleId.lowercased()
        let lowerTitle = title.lowercased()

        // Bundle-id match wins over title keywords; "other" only as fallback.
        for ctx in contexts where ctx.id != "other" {
            for id in ctx.appBundleIds where !id.isEmpty && lowerBundle == id.lowercased() {
                return ctx
            }
        }
        if !lowerTitle.isEmpty {
            for ctx in contexts where ctx.id != "other" {
                for keyword in ctx.titleKeywords where !keyword.isEmpty && lowerTitle.contains(keyword.lowercased()) {
                    return ctx
                }
            }
        }
        return nil
    }

    /// What is keyboard focus pointing at in the frontmost app right now?
    enum FocusedTextTarget {
        case acceptsText   // a text field/area/editor has focus
        case rejectsText   // focus is on something that is definitely not text (desktop, button, list…)
        case unknown       // accessibility couldn't tell us (AX untrusted, app exposes nothing)
    }

    /// Probe the focused element for a text cursor.
    /// Native fields usually expose AXSelectedTextRange. Web/Electron editors
    /// such as Codex may instead expose only a text role, AXEditable, or a
    /// settable value, so recognize all of those signals. Apps with broken or
    /// missing AX support return `.unknown` — callers should treat that as
    /// pasteable, and reserve copy-only for a definite `.rejectsText`.
    static func focusedTextTarget() -> FocusedTextTarget {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused,
              CFGetTypeID(el) == AXUIElementGetTypeID() else { return .unknown }
        var element = el as! AXUIElement

        // Some web views report focus on a wrapper around the contenteditable
        // node. Check a few ancestors as well as the focused element itself.
        for _ in 0..<4 {
            if elementAcceptsText(element) { return .acceptsText }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        // The app answered and nothing in the focus chain takes text.
        return .rejectsText
    }

    private static func elementAcceptsText(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attrs = names as? [String] else { return false }
        if attrs.contains(kAXSelectedTextRangeAttribute as String) { return true }

        if attrs.contains("AXEditable") {
            var editable: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
               let flag = editable as? Bool,
               flag {
                return true
            }
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard textRoles.contains(role) else { return false }

        // Read-only code blocks can also have text roles. A settable value is the
        // final confirmation that this particular element accepts input.
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // Runs synchronously on the main thread at hotkey time — a hung target app
        // must not be able to stall us for the default multi-second AX timeout.
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        let windowElement = win as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
