import AppKit
import Foundation
import Testing
@testable import Prompter

@Suite("Multiple hotkeys")
@MainActor
struct MultipleHotkeyTests {
    @Test("Existing primary shortcuts survive old and malformed config")
    func migration() throws {
        let data = Data(#"{"dictationHotkey":"mouse:3","promptHotkey":"rightShift","additionalDictationHotkeys":"invalid","liveTypingEnabled":true}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: data)
        #expect(config.hotkeyValues(for: .dictate) == ["mouse:3"])
        #expect(config.hotkeyValues(for: .prompt) == ["rightShift"])
        #expect(config.liveTypingEnabled)
    }

    @Test("Additional keyboard and mouse shortcuts persist across encoding")
    func persistence() throws {
        var config = Config()
        let combo = HotkeyShortcut(keyCode: 2, modifiers: [.command, .control])
        #expect(config.setHotkey(combo, for: .dictate) == nil)
        #expect(config.setHotkey(HotkeyShortcut(mouseButtonNumber: 3), for: .dictate) == nil)
        #expect(config.setHotkey(HotkeyShortcut(mouseButtonNumber: 4), for: .prompt) == nil)
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.hotkeyValues(for: .dictate) == ["rightOption", combo.storedValue, "mouse:3"])
        #expect(restored.hotkeyValues(for: .prompt) == ["rightCommand", "mouse:4"])
    }

    @Test("Equivalent preset and custom encodings are one shortcut")
    func canonicalDuplicates() {
        let preset = HotkeyShortcut(preset: .rightOption)
        let custom = HotkeyShortcut(keyCode: 61, modifiers: .option, isModifierOnly: true)
        #expect(preset == custom)
        var config = Config()
        config.additionalDictationHotkeys = ["custom:61:\(NSEvent.ModifierFlags.option.rawValue):1", "mouse:3", "mouse:3", "bad"]
        #expect(config.hotkeyValues(for: .dictate) == ["rightOption", "mouse:3"])
        #expect(config.setHotkey(custom, for: .dictate) != nil)
        #expect(config.setHotkey(custom, for: .prompt) != nil)
    }

    @Test("Conflicts reject edits without replacing an existing shortcut")
    func conflicts() {
        var config = Config()
        let button = HotkeyShortcut(mouseButtonNumber: 3)
        #expect(config.setHotkey(button, for: .dictate) == nil)
        #expect(config.setHotkey(button, for: .dictate) != nil)
        #expect(config.setHotkey(button, for: .prompt, replacing: 0) != nil)
        #expect(config.promptHotkey == "rightCommand")
        #expect(config.hotkeyValues(for: .dictate) == ["rightOption", "mouse:3"])
        #expect(config.setHotkey(button, for: .dictate, replacing: 1) == nil)
    }

    @Test("Removing the first shortcut promotes another and retains at least one")
    func removePrimary() {
        var config = Config()
        config.additionalDictationHotkeys = ["mouse:3", "rightShift"]
        config.removeHotkey(at: 0, for: .dictate)
        #expect(config.dictationHotkey == "mouse:3")
        #expect(config.additionalDictationHotkeys == ["rightShift"])
        config.removeHotkey(at: 1, for: .dictate)
        config.removeHotkey(at: 0, for: .dictate)
        #expect(config.hotkeyValues(for: .dictate) == ["mouse:3"])
    }

    @Test("An additional modifier starts hands-free and another mouse shortcut stops it")
    func modifierToMouse() throws {
        var config = Config()
        config.additionalDictationHotkeys = ["rightShift", "mouse:3"]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var begins: [DictationMode] = []
        var commits = 0
        monitor.onBegin = { mode, handsFree in
            #expect(handsFree)
            begins.append(mode)
        }
        monitor.onCommit = { commits += 1 }
        monitor.handleFlagsChanged(try key(.flagsChanged, 60, .shift))
        monitor.handleFlagsChanged(try key(.flagsChanged, 60))
        #expect(begins == [.dictate])
        monitor.handleMouseDown(try mouse(.otherMouseDown, 3))
        monitor.handleMouseUp(try mouse(.otherMouseUp, 3))
        #expect(commits == 1)
        #expect(begins.count == 1)
    }

    @Test("A mouse shortcut starts and an additional key combination stops hands-free")
    func mouseToKeyboard() throws {
        var config = Config()
        config.additionalDictationHotkeys = ["mouse:3", HotkeyShortcut(keyCode: 2, modifiers: [.command, .control]).storedValue]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var begins = 0
        var commits = 0
        monitor.onBegin = { _, _ in begins += 1 }
        monitor.onCommit = { commits += 1 }
        monitor.handleMouseDown(try mouse(.otherMouseDown, 3))
        monitor.handleMouseUp(try mouse(.otherMouseUp, 3))
        monitor.handleKeyDown(try key(.keyDown, 2, [.command, .control]))
        monitor.handleKeyUp(try key(.keyUp, 2, [.command, .control]))
        #expect(begins == 1)
        #expect(commits == 1)
    }

    @Test("Prompt aliases start Prompt Mode and Dictation keys do not stop it")
    func modeIsolation() throws {
        var config = Config()
        config.additionalPromptHotkeys = ["mouse:4", "rightShift"]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var mode: DictationMode?
        var commits = 0
        monitor.onBegin = { m, _ in mode = m }
        monitor.onCommit = { commits += 1 }
        monitor.handleMouseDown(try mouse(.otherMouseDown, 4))
        monitor.handleMouseUp(try mouse(.otherMouseUp, 4))
        #expect(mode == .prompt)
        monitor.handleFlagsChanged(try key(.flagsChanged, 61, .option))
        monitor.handleFlagsChanged(try key(.flagsChanged, 61))
        #expect(commits == 0)
        monitor.handleFlagsChanged(try key(.flagsChanged, 60, .shift))
        #expect(commits == 1)
    }

    @Test("Held recording ends only when the initiating shortcut is released")
    func heldRelease() async throws {
        var config = Config()
        config.holdThresholdMs = 1
        config.additionalDictationHotkeys = ["mouse:3", "mouse:4"]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var heldStarts = 0
        var commits = 0
        monitor.onBegin = { _, handsFree in if !handsFree { heldStarts += 1 } }
        monitor.onCommit = { commits += 1 }
        monitor.handleMouseDown(try mouse(.otherMouseDown, 3))
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(heldStarts == 1)
        monitor.handleMouseUp(try mouse(.otherMouseUp, 4))
        #expect(commits == 0)
        monitor.handleMouseUp(try mouse(.otherMouseUp, 3))
        #expect(commits == 1)
    }

    @Test("An additional key combination starts Prompt Mode and Escape cancels")
    func combinationAndCancel() throws {
        var config = Config()
        config.additionalPromptHotkeys = [HotkeyShortcut(keyCode: 2, modifiers: [.command, .control]).storedValue]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var mode: DictationMode?
        var aborts = 0
        monitor.onBegin = { m, _ in mode = m }
        monitor.onAbort = { aborts += 1 }
        monitor.handleKeyDown(try key(.keyDown, 2, [.command, .control]))
        monitor.handleKeyUp(try key(.keyUp, 2, [.command, .control]))
        #expect(mode == .prompt)
        monitor.handleKeyDown(try key(.keyDown, 53))
        #expect(aborts == 1)
    }

    @Test("A registered combination supersedes its pending standalone modifier")
    func overlappingStart() throws {
        var config = Config()
        config.additionalDictationHotkeys = [HotkeyShortcut(keyCode: 2, modifiers: .option).storedValue]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var begins = 0
        monitor.onBegin = { mode, _ in
            #expect(mode == .dictate)
            begins += 1
        }
        monitor.handleFlagsChanged(try key(.flagsChanged, 61, .option))
        monitor.handleKeyDown(try key(.keyDown, 2, .option))
        monitor.handleKeyUp(try key(.keyUp, 2, .option))
        #expect(begins == 1)
    }

    @Test("Finishing with an overlapping combination cannot restart dictation")
    func overlappingFinish() throws {
        var config = Config()
        config.additionalDictationHotkeys = [HotkeyShortcut(keyCode: 2, modifiers: .option).storedValue]
        let monitor = HotkeyMonitor(configProvider: { config })
        defer { monitor.stop() }
        var begins = 0
        var commits = 0
        monitor.onBegin = { _, _ in begins += 1 }
        monitor.onCommit = { commits += 1 }
        monitor.handleFlagsChanged(try key(.flagsChanged, 61, .option))
        monitor.handleFlagsChanged(try key(.flagsChanged, 61))
        monitor.handleFlagsChanged(try key(.flagsChanged, 61, .option))
        monitor.handleKeyDown(try key(.keyDown, 2, .option))
        monitor.handleKeyUp(try key(.keyUp, 2, .option))
        monitor.handleFlagsChanged(try key(.flagsChanged, 61))
        #expect(begins == 1)
        #expect(commits == 1)
        monitor.handleFlagsChanged(try key(.flagsChanged, 61, .option))
        monitor.handleFlagsChanged(try key(.flagsChanged, 61))
        #expect(begins == 2)
    }

    @Test("Live typing recognizes every assigned finishing shortcut")
    func liveTypingControls() throws {
        let combo = HotkeyShortcut(keyCode: 2, modifiers: [.command, .control])
        let shortcuts = [HotkeyShortcut(preset: .rightOption), combo, HotkeyShortcut(mouseButtonNumber: 3)]
        #expect(LiveTextSession.isControlEvent(try key(.keyDown, 2, [.command, .control]), shortcuts: shortcuts))
        #expect(LiveTextSession.isControlEvent(try mouse(.otherMouseDown, 3), shortcuts: shortcuts))
        #expect(!LiveTextSession.isControlEvent(try key(.keyDown, 2), shortcuts: shortcuts))
        #expect(!LiveTextSession.isControlEvent(try mouse(.leftMouseDown, 0), shortcuts: shortcuts))
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }

    private func mouse(_ type: CGEventType, _ button: Int) throws -> NSEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                        mouseButton: CGMouseButton(rawValue: UInt32(button))!))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return try #require(NSEvent(cgEvent: event))
    }
}
