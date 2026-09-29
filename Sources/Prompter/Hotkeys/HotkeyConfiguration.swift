import Foundation

extension Config {
    /// The original single values remain the primary shortcuts for backward
    /// compatibility and onboarding; additional shortcuts are optional.
    func shortcuts(for mode: DictationMode) -> [HotkeyShortcut] {
        let primary = mode == .dictate ? dictationHotkey : promptHotkey
        let extras = mode == .dictate ? additionalDictationHotkeys : additionalPromptHotkeys
        let fallback = HotkeyShortcut(preset: mode == .dictate ? .rightOption : .rightCommand)
        var shortcuts = [HotkeyShortcut(storedValue: primary) ?? fallback]
        for value in extras {
            guard let shortcut = HotkeyShortcut(storedValue: value), !shortcuts.contains(shortcut) else { continue }
            shortcuts.append(shortcut)
        }
        return shortcuts
    }

    func hotkeyValues(for mode: DictationMode) -> [String] {
        shortcuts(for: mode).map(\.storedValue)
    }

    func hotkeySummary(for mode: DictationMode) -> String {
        shortcuts(for: mode).map(\.shortDisplay).joined(separator: " or ")
    }

    var conflictingHotkeys: [HotkeyShortcut] {
        let prompt = shortcuts(for: .prompt)
        return shortcuts(for: .dictate).filter { prompt.contains($0) }
    }

    func hotkeyConflict(_ shortcut: HotkeyShortcut, for mode: DictationMode, replacing index: Int? = nil) -> String? {
        let own = shortcuts(for: mode)
        if own.enumerated().contains(where: { $0.offset != index && $0.element == shortcut }) {
            return "That shortcut is already assigned to \(mode == .dictate ? "Dictation" : "Prompt Mode")."
        }
        if shortcuts(for: mode == .dictate ? .prompt : .dictate).contains(shortcut) {
            return "That shortcut is already assigned to \(mode == .dictate ? "Prompt Mode" : "Dictation"). Choose another shortcut."
        }
        return nil
    }

    /// Returns a validation message without changing config when an assignment conflicts.
    @discardableResult
    mutating func setHotkey(_ shortcut: HotkeyShortcut, for mode: DictationMode, replacing index: Int? = nil) -> String? {
        if let message = hotkeyConflict(shortcut, for: mode, replacing: index) { return message }
        var values = hotkeyValues(for: mode)
        if let index {
            guard values.indices.contains(index) else { return "This shortcut changed. Try again." }
            values[index] = shortcut.storedValue
        } else {
            values.append(shortcut.storedValue)
        }
        saveHotkeyValues(values, for: mode)
        return nil
    }

    mutating func removeHotkey(at index: Int, for mode: DictationMode) {
        var values = hotkeyValues(for: mode)
        guard values.count > 1, values.indices.contains(index) else { return }
        values.remove(at: index)
        saveHotkeyValues(values, for: mode)
    }

    private mutating func saveHotkeyValues(_ values: [String], for mode: DictationMode) {
        guard let primary = values.first else { return }
        if mode == .dictate {
            dictationHotkey = primary
            additionalDictationHotkeys = Array(values.dropFirst())
        } else {
            promptHotkey = primary
            additionalPromptHotkeys = Array(values.dropFirst())
        }
    }
}
