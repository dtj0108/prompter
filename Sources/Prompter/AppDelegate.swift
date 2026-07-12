import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var hotkeyInfoItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prompts.ensurePromptModeFileExists()
        setupMainMenu()
        setupStatusItem()
        DictationController.shared.start()
        HUD.shared.start()
        Log.write("Prompter launched")

        // First run: the setup assistant walks through permissions and the AI key.
        if !ConfigStore.shared.config.onboardingDone {
            WindowRouter.shared.openOnboarding()
        }
    }

    /// Accessory (menu-bar-only) apps have no main menu, so ⌘V/⌘C/⌘X/⌘A have
    /// nothing to route through and silently do nothing in our windows — you
    /// couldn't even paste an API key. A hidden Edit menu fixes all of them.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
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
        menu.addItem(makeItem("Snippets…", #selector(openSnippets), "s"))
        menu.addItem(makeItem("Style…", #selector(openStyle), "t"))
        menu.addItem(makeItem("Insights…", #selector(openInsights), "i"))
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))

        menu.addItem(.separator())

        menu.addItem(makeItem("Setup Assistant…", #selector(openOnboarding), ""))

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
        let verb = config.tapToLockEnabled ? "Hold or tap" : "Hold"
        return "\(verb) \(dictate) to dictate  •  \(prompt) for Prompt Mode"
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
    @objc private func openSnippets() { WindowRouter.shared.openSnippets() }
    @objc private func openStyle() { WindowRouter.shared.openStyle() }
    @objc private func openInsights() { WindowRouter.shared.openInsights() }
    @objc private func openSettings() { WindowRouter.shared.openSettings() }
    @objc private func openOnboarding() { WindowRouter.shared.openOnboarding() }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        hotkeyInfoItem?.title = hotkeyInfoText()
    }
}
