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

/// Hold-to-talk (hold, talk, release) and hands-free (tap, talk, tap again) for
/// both the built-in right-side modifier choices and user-recorded shortcuts.
/// Event monitors remain passive: modifier/function shortcuts are recommended so
/// Prompter never steals ordinary typing or existing system shortcuts.
final class HotkeyMonitor {
    /// (mode, handsFree)
    var onBegin: ((DictationMode, Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onAbort: (() -> Void)?

    private enum State {
        case idle
        case pending(mode: DictationMode, shortcut: HotkeyShortcut)
        case active(mode: DictationMode, shortcut: HotkeyShortcut)
        /// Hands-free: recording continues after the tap; next tap of the same key commits.
        case latched(mode: DictationMode, shortcut: HotkeyShortcut)
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
        let keyUpHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleKeyUp(event)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: keyUpHandler) { monitors.append(m) }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyHandler(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            keyUpHandler(event)
            return event
        } as Any)
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        holdTimer?.cancel()
        state = .idle
    }

    /// Drop an in-progress key gesture without unregistering the event monitors.
    /// Used while a shortcut-recorder UI has keyboard focus.
    func resetState() {
        holdTimer?.cancel()
        state = .idle
    }

    private var dictationShortcut: HotkeyShortcut {
        HotkeyShortcut(storedValue: ConfigStore.shared.config.dictationHotkey)
            ?? HotkeyShortcut(preset: .rightOption)
    }
    private var promptShortcut: HotkeyShortcut {
        HotkeyShortcut(storedValue: ConfigStore.shared.config.promptHotkey)
            ?? HotkeyShortcut(preset: .rightCommand)
    }

    private var candidates: [(HotkeyShortcut, DictationMode)] {
        [
            (dictationShortcut, .dictate),
            (promptShortcut, .prompt),
        ]
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let code = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch state {
        case .idle:
            for (shortcut, mode) in candidates where shortcut.isModifierOnly && code == shortcut.keyCode {
                // Key must be going DOWN (its flag now present) and be the only modifier
                // held. Caps Lock doesn't count — it sits in the flags of every event
                // while engaged and would otherwise silently disable the hotkeys.
                guard shortcut.modifierIsDown(in: event),
                      flags.intersection(HotkeyShortcut.relevantModifiers) == shortcut.modifiers else { return }
                beginPending(mode: mode, shortcut: shortcut)
                return
            }

        case .pending(let mode, let shortcut):
            if !shortcut.isModifierOnly {
                if !shortcut.requiredModifiersAreDown(in: event) {
                    completeTap(mode: mode, shortcut: shortcut)
                }
                return
            }

            // The same key can't be pressed twice, so a same-key event before the hold
            // threshold is its release — a TAP. A different key means a shortcut chord.
            holdTimer?.cancel()
            if code == shortcut.keyCode, !shortcut.modifierIsDown(in: event) {
                completeTap(mode: mode, shortcut: shortcut)
            } else {
                state = .idle
            }

        case .active(_, let shortcut):
            // A second event for the held key is necessarily its release. Judging by
            // keyCode (not aggregate flags) keeps this correct when the same-named
            // modifier on the other side of the keyboard is also down.
            let released = shortcut.isModifierOnly
                ? code == shortcut.keyCode && !shortcut.modifierIsDown(in: event)
                : !shortcut.requiredModifiersAreDown(in: event)
            if released {
                state = .idle
                onCommit?()
            }

        case .latched(_, let shortcut):
            // Next PRESS of the same key (flag present) finishes the hands-free session.
            // Its paired release event arrives in .idle with the flag absent and is
            // ignored by the idle guard there.
            if shortcut.isModifierOnly, code == shortcut.keyCode, shortcut.modifierIsDown(in: event) {
                state = .idle
                onCommit?()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch state {
        case .idle:
            guard !event.isARepeat else { return }
            for (shortcut, mode) in candidates where shortcut.matchesKeyDown(event) {
                beginPending(mode: mode, shortcut: shortcut)
                return
            }
            return

        case .pending(_, let shortcut):
            if !shortcut.isModifierOnly,
               event.keyCode == shortcut.keyCode,
               event.isARepeat { return }
            // Any real key while the modifier is held = a normal shortcut. Stand down.
            holdTimer?.cancel()
            state = .idle

        case .active(_, let shortcut):
            if !shortcut.isModifierOnly,
               event.keyCode == shortcut.keyCode,
               event.isARepeat { return }
            if event.keyCode == 53 { // Esc cancels
                state = .idle
                onAbort?()
            } else {
                // User started typing a shortcut mid-dictation; abort so we don't fight them.
                state = .idle
                onAbort?()
            }

        case .latched(_, let shortcut):
            if !shortcut.isModifierOnly, !event.isARepeat, shortcut.matchesKeyDown(event) {
                state = .idle
                onCommit?()
                return
            }
            // Hands-free survives typing and clicking around — only Esc cancels.
            if event.keyCode == 53 {
                state = .idle
                onAbort?()
            }
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        switch state {
        case .pending(let mode, let shortcut):
            guard !shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return }
            completeTap(mode: mode, shortcut: shortcut)

        case .active(_, let shortcut):
            guard !shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return }
            state = .idle
            onCommit?()

        case .idle, .latched:
            return
        }
    }

    private func completeTap(mode: DictationMode, shortcut: HotkeyShortcut) {
        holdTimer?.cancel()
        if ConfigStore.shared.config.tapToLockEnabled {
            state = .latched(mode: mode, shortcut: shortcut)
            onBegin?(mode, true)
        } else {
            state = .idle
        }
    }

    private func beginPending(mode: DictationMode, shortcut: HotkeyShortcut) {
        holdTimer?.cancel()
        state = .pending(mode: mode, shortcut: shortcut)
        let threshold = Double(ConfigStore.shared.config.holdThresholdMs) / 1000.0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .pending(let mode, let shortcut) = self.state {
                self.state = .active(mode: mode, shortcut: shortcut)
                self.onBegin?(mode, false)
            }
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
    }

}
