import AppKit

enum HotkeyKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightShift
    case fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightShift: return .shift
        case .fn: return .function
        }
    }

    var display: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightShift: return "Right ⇧ Shift"
        case .fn: return "fn (Globe)"
        }
    }

    var shortDisplay: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightShift: return "Right ⇧"
        case .fn: return "fn"
        }
    }
}

/// Hold-to-talk (hold key, talk, release) and hands-free (tap key, talk as long as
/// you want, tap again to finish) on a right-side modifier key.
/// Passive (never swallows events): holding the key alone does nothing system-wide,
/// and if the user presses any other key mid-hold we abort so normal shortcuts pass through.
final class HotkeyMonitor {
    /// (mode, handsFree)
    var onBegin: ((DictationMode, Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onAbort: (() -> Void)?

    private enum State {
        case idle
        case pending(mode: DictationMode, keyCode: UInt16)
        case active(mode: DictationMode, keyCode: UInt16)
        /// Hands-free: recording continues after the tap; next tap of the same key commits.
        case latched(mode: DictationMode, keyCode: UInt16)
    }

    private var state: State = .idle
    private var holdTimer: DispatchWorkItem?
    private var monitors: [Any] = []

    func start() {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleKeyDown(event)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event)
            return event
        } as Any)
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        holdTimer?.cancel()
        state = .idle
    }

    private var dictationKey: HotkeyKey {
        HotkeyKey(rawValue: ConfigStore.shared.config.dictationHotkey) ?? .rightOption
    }
    private var promptKey: HotkeyKey {
        HotkeyKey(rawValue: ConfigStore.shared.config.promptHotkey) ?? .rightCommand
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let code = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch state {
        case .idle:
            let candidates: [(HotkeyKey, DictationMode)] = [
                (dictationKey, .dictate),
                (promptKey, .prompt),
            ]
            for (key, mode) in candidates where code == key.keyCode {
                // Key must be going DOWN (its flag now present) and be the only modifier
                // held. Caps Lock doesn't count — it sits in the flags of every event
                // while engaged and would otherwise silently disable the hotkeys.
                guard flags.contains(key.flag),
                      flags.subtracting([key.flag, .capsLock]).isEmpty else { return }
                beginPending(mode: mode, keyCode: code)
                return
            }

        case .pending(let mode, let keyCode):
            // The same key can't be pressed twice, so a same-key event before the hold
            // threshold is its release — a TAP. A different key means a shortcut chord.
            holdTimer?.cancel()
            if code == keyCode, ConfigStore.shared.config.tapToLockEnabled {
                state = .latched(mode: mode, keyCode: keyCode)
                onBegin?(mode, true)
            } else {
                state = .idle
            }

        case .active(_, let keyCode):
            // A second event for the held key is necessarily its release. Judging by
            // keyCode (not aggregate flags) keeps this correct when the same-named
            // modifier on the other side of the keyboard is also down.
            if code == keyCode {
                state = .idle
                onCommit?()
            }

        case .latched(_, let keyCode):
            // Next PRESS of the same key (flag present) finishes the hands-free session.
            // Its paired release event arrives in .idle with the flag absent and is
            // ignored by the idle guard there.
            if code == keyCode, let key = HotkeyKey.allCases.first(where: { $0.keyCode == code }),
               flags.contains(key.flag) {
                state = .idle
                onCommit?()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch state {
        case .idle:
            return
        case .pending:
            // Any real key while the modifier is held = a normal shortcut. Stand down.
            holdTimer?.cancel()
            state = .idle
        case .active:
            if event.keyCode == 53 { // Esc cancels
                state = .idle
                onAbort?()
            } else {
                // User started typing a shortcut mid-dictation; abort so we don't fight them.
                state = .idle
                onAbort?()
            }

        case .latched:
            // Hands-free survives typing and clicking around — only Esc cancels.
            if event.keyCode == 53 {
                state = .idle
                onAbort?()
            }
        }
    }

    private func beginPending(mode: DictationMode, keyCode: UInt16) {
        holdTimer?.cancel()
        state = .pending(mode: mode, keyCode: keyCode)
        let threshold = Double(ConfigStore.shared.config.holdThresholdMs) / 1000.0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .pending(let mode, let keyCode) = self.state {
                self.state = .active(mode: mode, keyCode: keyCode)
                self.onBegin?(mode, false)
            }
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
    }

}
