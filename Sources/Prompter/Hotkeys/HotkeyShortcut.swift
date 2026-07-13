import AppKit

/// A saved hotkey. The original four choices keep their stable string values;
/// custom shortcuts are encoded into the same config fields as
/// `custom:<keyCode>:<modifierFlags>:<modifierOnly>` so existing installs need
/// no migration and old versions still fall back safely.
struct HotkeyShortcut: Equatable {
    private static let customPrefix = "custom"
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let isModifierOnly: Bool
    let preset: HotkeyKey?

    init(preset: HotkeyKey) {
        keyCode = preset.keyCode
        modifiers = preset.flag
        isModifierOnly = true
        self.preset = preset
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isModifierOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
        self.isModifierOnly = isModifierOnly
        preset = nil
    }

    init?(storedValue: String) {
        if let preset = HotkeyKey(rawValue: storedValue) {
            self.init(preset: preset)
            return
        }

        let pieces = storedValue.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              pieces[0] == Self.customPrefix,
              let keyCode = UInt16(pieces[1]),
              let rawModifiers = UInt(pieces[2]),
              let modifierOnly = Int(pieces[3]) else { return nil }

        self.init(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: rawModifiers),
            isModifierOnly: modifierOnly == 1
        )
    }

    var storedValue: String {
        if let preset { return preset.rawValue }
        if isModifierOnly,
           let matchingPreset = HotkeyKey.allCases.first(where: {
               $0.keyCode == keyCode && $0.flag == modifiers
           }) {
            return matchingPreset.rawValue
        }
        return "\(Self.customPrefix):\(keyCode):\(modifiers.rawValue):\(isModifierOnly ? 1 : 0)"
    }

    var display: String {
        if let preset { return preset.display }
        if isModifierOnly { return Self.modifierKeyName(for: keyCode, shortened: false) }
        return Self.modifierSymbols(modifiers) + Self.keyName(for: keyCode)
    }

    var shortDisplay: String {
        if let preset { return preset.shortDisplay }
        if isModifierOnly { return Self.modifierKeyName(for: keyCode, shortened: true) }
        return Self.modifierSymbols(modifiers) + Self.keyName(for: keyCode)
    }

    static func display(for storedValue: String, fallback: HotkeyKey, shortened: Bool = false) -> String {
        let shortcut = HotkeyShortcut(storedValue: storedValue) ?? HotkeyShortcut(preset: fallback)
        return shortened ? shortcut.shortDisplay : shortcut.display
    }

    static func matches(_ first: String, _ second: String) -> Bool {
        guard let firstShortcut = HotkeyShortcut(storedValue: first),
              let secondShortcut = HotkeyShortcut(storedValue: second) else { return false }
        return firstShortcut == secondShortcut
    }

    func matchesKeyDown(_ event: NSEvent) -> Bool {
        guard !isModifierOnly, event.keyCode == keyCode else { return false }
        let eventModifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        return eventModifiers == modifiers
    }

    func modifierIsDown(in event: NSEvent) -> Bool {
        guard isModifierOnly, let flag = Self.modifierFlag(for: keyCode) else { return false }
        return event.modifierFlags.contains(flag)
    }

    func requiredModifiersAreDown(in event: NSEvent) -> Bool {
        event.modifierFlags.intersection(Self.relevantModifiers).isSuperset(of: modifiers)
    }

    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        if flags.contains(.function) { result += "fn " }
        return result
    }

    private static func modifierKeyName(for keyCode: UInt16, shortened: Bool) -> String {
        switch keyCode {
        case 54: return shortened ? "Right ⌘" : "Right ⌘ Command"
        case 55: return shortened ? "Left ⌘" : "Left ⌘ Command"
        case 56: return shortened ? "Left ⇧" : "Left ⇧ Shift"
        case 58: return shortened ? "Left ⌥" : "Left ⌥ Option"
        case 59: return shortened ? "Left ⌃" : "Left ⌃ Control"
        case 60: return shortened ? "Right ⇧" : "Right ⇧ Shift"
        case 61: return shortened ? "Right ⌥" : "Right ⌥ Option"
        case 62: return shortened ? "Right ⌃" : "Right ⌃ Control"
        case 63: return shortened ? "fn" : "fn (Globe)"
        default: return keyName(for: keyCode)
        }
    }

    /// Hardware key-code labels for the standard Mac keyboard. They remain
    /// stable when the user changes keyboard layout, which is important because
    /// the saved shortcut is intentionally tied to the physical key they pressed.
    private static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear",
            75: "Keypad /", 76: "Keypad Enter", 78: "Keypad −", 79: "F18", 80: "F19",
            81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
            85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
            89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}
