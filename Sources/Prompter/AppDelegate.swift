import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pauseItem: NSMenuItem?
    private var hotkeyInfoItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ActiveAppMonitor.shared.start()
        Prompts.ensurePromptModeFileExists()
        setupMainMenu()
        DictationController.shared.start()
        HUD.shared.start()
        AppUpdater.shared.checkForUpdates()
        // The launch-time check goes stale on a long-running app; re-check
        // periodically so releases published afterwards still surface.
        let updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            DispatchQueue.main.async {
                if case .available = AppUpdater.shared.state { return }
                AppUpdater.shared.checkForUpdates()
            }
        }
        RunLoop.main.add(updateTimer, forMode: .common)
        Log.write("Prompter launched")

        // Prompter is a regular Dock app: always present a window at launch.
        presentLaunchWindow()
    }

    /// Double-clicking Prompter in Applications while it's already running lands here:
    /// open the main window (or the setup assistant if it was never finished).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentLaunchWindow()
        return true
    }

    /// Main window normally — but if a required permission is missing (an app
    /// update resets TCC grants), reopen the setup assistant on the broken step
    /// so the user can re-grant instead of silently having dead hotkeys.
    private func presentLaunchWindow() {
        guard ConfigStore.shared.config.onboardingDone else {
            WindowRouter.shared.openOnboarding()
            return
        }
        if !Recorder.micAuthorized() {
            Log.write("microphone permission missing at launch — reopening setup assistant")
            WindowRouter.shared.openOnboarding(startStep: 1)
        } else if !AXIsProcessTrusted() {
            Log.write("accessibility permission missing at launch — reopening setup assistant")
            WindowRouter.shared.openOnboarding(startStep: 2)
        } else {
            WindowRouter.shared.openMain()
        }
    }

    /// Install a standard macOS menu bar for the Dock application. This keeps
    /// editing shortcuts working and relocates the old status-item actions into
    /// ordinary application/navigation menus.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(title: "Prompter", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Prompter")
        appMenu.delegate = self
        appMenu.addItem(NSMenuItem(title: "About Prompter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settings = makeItem("Settings…", #selector(openSettings), ",")
        appMenu.addItem(settings)
        let setup = makeItem("Setup Assistant…", #selector(openOnboarding), "")
        appMenu.addItem(setup)
        appMenu.addItem(.separator())
        let pause = makeItem("Pause Prompter", #selector(togglePause), "")
        appMenu.addItem(pause)
        pauseItem = pause
        let info = NSMenuItem(title: hotkeyInfoText(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        appMenu.addItem(info)
        hotkeyInfoItem = info
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Prompter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
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

        let navigateItem = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        let navigate = NSMenu(title: "Navigate")
        navigate.addItem(makeItem("Home", #selector(openMainWindow), "1"))
        navigate.addItem(makeItem("Insights", #selector(openInsights), "2"))
        navigate.addItem(makeItem("Dictionary", #selector(openDictionary), "3"))
        navigate.addItem(makeItem("Snippets", #selector(openSnippets), "4"))
        navigate.addItem(makeItem("Style", #selector(openStyle), "5"))
        navigate.addItem(makeItem("Settings", #selector(openSettings), "6"))
        navigateItem.submenu = navigate
        main.addItem(navigateItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func hotkeyInfoText() -> String {
        let config = ConfigStore.shared.config
        let dictate = HotkeyShortcut.display(for: config.dictationHotkey, fallback: .rightOption, shortened: true)
        let prompt = HotkeyShortcut.display(for: config.promptHotkey, fallback: .rightCommand, shortened: true)
        let verb = config.tapToLockEnabled ? "Hold or tap" : "Hold"
        return "\(verb) \(dictate) to dictate  •  \(prompt) for Prompt Mode"
    }

    @objc private func togglePause() {
        DictationController.shared.isPaused.toggle()
        let paused = DictationController.shared.isPaused
        pauseItem?.title = paused ? "Resume Prompter" : "Pause Prompter"
    }

    @objc private func openMainWindow() { WindowRouter.shared.openMain() }
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
