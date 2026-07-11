import AppKit
import Carbon.HIToolbox

enum PasteResult {
    case pasted
    case clipboardOnly(reason: String)
}

enum Paster {

    // Back-to-back dictations: if the clipboard still holds OUR previous text when a
    // new insert starts, carry the user's original snapshot forward instead of
    // re-snapshotting our own text — otherwise the original clipboard is lost.
    private static var pendingOriginal: (items: [NSPasteboardItem], concealed: Bool)?
    private static var lastWriteChangeCount: Int = -1
    private static var restoreWork: DispatchWorkItem?

    /// Insert text at the cursor of the frontmost app by temporarily hijacking the
    /// pasteboard. With `allowPaste: false` the text is only copied (caller decides why).
    static func insert(_ text: String, allowPaste: Bool = true) -> PasteResult {
        let pasteboard = NSPasteboard.general
        restoreWork?.cancel()
        restoreWork = nil

        let saved: (items: [NSPasteboardItem], concealed: Bool)
        if pasteboard.changeCount == lastWriteChangeCount, let pending = pendingOriginal {
            saved = pending
        } else {
            saved = snapshot(pasteboard)
        }
        pendingOriginal = saved

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWriteChangeCount = pasteboard.changeCount
        let ourChangeCount = lastWriteChangeCount

        guard allowPaste else {
            return .clipboardOnly(reason: "Copied — press ⌘V to paste")
        }
        if IsSecureEventInputEnabled() {
            // A password field has keyboard focus; don't fight it.
            return .clipboardOnly(reason: "Secure field — text is on your clipboard, press ⌘V")
        }
        guard AXIsProcessTrusted() else {
            return .clipboardOnly(reason: "Copied — grant Accessibility to auto-paste")
        }
        guard sendCmdV() else {
            return .clipboardOnly(reason: "Copied — press ⌘V to paste")
        }

        // Restore the previous clipboard once the paste has landed — but only if
        // nothing else was copied meanwhile, and never resurrect concealed
        // (password-manager) content.
        let restoreDelay = max(0.3, Double(ConfigStore.shared.config.pasteRestoreDelayMs) / 1000.0)
        let work = DispatchWorkItem {
            defer {
                pendingOriginal = nil
                restoreWork = nil
            }
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.items.isEmpty && !saved.concealed {
                pasteboard.writeObjects(saved.items)
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        return .pasted
    }

    /// Snapshot the current clipboard, all types. Items must be copied into fresh
    /// NSPasteboardItems — originals become invalid after clearContents().
    private static func snapshot(_ pasteboard: NSPasteboard) -> (items: [NSPasteboardItem], concealed: Bool) {
        var items: [NSPasteboardItem] = []
        var concealed = false
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if type.rawValue == "org.nspasteboard.ConcealedType" { concealed = true }
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            items.append(copy)
        }
        return (items, concealed)
    }

    private static func sendCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Keep the user's physically-held keys (the just-released hotkey, etc.)
        // from contaminating the synthetic event.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
