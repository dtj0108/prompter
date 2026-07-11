import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var hotkeyInfoItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prompts.ensurePromptModeFileExists()
        setupStatusItem()
        DictationController.shared.start()
        Log.write("Prompter launched")

        // First-run: nudge for permissions.
        if !Recorder.micAuthorized() || !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt" as CFString as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Task { _ = await Recorder.requestMicAccess() }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Prompter")
        }

        let menu = NSMenu()

        let info = NSMenuItem(title: hotkeyInfoText(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        hotkeyInfoItem = info

        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause Prompter", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        menu.addItem(.separator())

        menu.addItem(makeItem("Dictionary…", #selector(openDictionary), "d"))
        menu.addItem(makeItem("Style…", #selector(openStyle), "t"))
        menu.addItem(makeItem("Insights…", #selector(openInsights), "i"))
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func hotkeyInfoText() -> String {
        let config = ConfigStore.shared.config
        let dictate = HotkeyKey(rawValue: config.dictationHotkey)?.shortDisplay ?? "?"
        let prompt = HotkeyKey(rawValue: config.promptHotkey)?.shortDisplay ?? "?"
        return "Hold \(dictate) to dictate  •  Hold \(prompt) for Prompt Mode"
    }

    @objc private func togglePause() {
        DictationController.shared.isPaused.toggle()
        let paused = DictationController.shared.isPaused
        pauseItem?.title = paused ? "Resume Prompter" : "Pause Prompter"
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: paused ? "waveform.slash" : "waveform.circle.fill",
                accessibilityDescription: "Prompter"
            )
        }
    }

    @objc private func openDictionary() { WindowRouter.shared.openDictionary() }
    @objc private func openStyle() { WindowRouter.shared.openStyle() }
    @objc private func openInsights() { WindowRouter.shared.openInsights() }
    @objc private func openSettings() { WindowRouter.shared.openSettings() }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        hotkeyInfoItem?.title = hotkeyInfoText()
    }
}
