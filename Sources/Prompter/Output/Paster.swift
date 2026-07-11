import AppKit
import Carbon.HIToolbox

enum PasteResult {
    case pasted
    case clipboardOnly(reason: String)
}

enum Paster {

    /// Insert text at the cursor of the frontmost app by temporarily hijacking the pasteboard.
    /// Falls back to leaving the text on the clipboard when pasting isn't possible.
    static func insert(_ text: String) -> PasteResult {
        let pasteboard = NSPasteboard.general

        // Snapshot the current clipboard, all types. Items must be copied into fresh
        // NSPasteboardItems — originals become invalid after clearContents().
        var saved: [NSPasteboardItem] = []
        var hadConcealed = false
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if type.rawValue == "org.nspasteboard.ConcealedType" { hadConcealed = true }
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

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
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty && !hadConcealed {
                pasteboard.writeObjects(saved)
            }
        }
        return .pasted
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
