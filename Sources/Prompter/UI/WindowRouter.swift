import AppKit
import SwiftUI

final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()

    private var windows: [String: NSWindow] = [:]

    /// `chromeless` windows hide the title bar and extend content to the full
    /// frame (traffic lights overlay the content, size is fixed) — the
    /// Ambitious onboarding card style.
    func open<Content: View>(key: String, title: String, size: NSSize, chromeless: Bool = false, @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let styleMask: NSWindow.StyleMask = chromeless
            ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        if chromeless {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(content()))
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(key)
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
    }

    /// The Flow-style main window: sidebar with Home/Insights/Dictionary/Snippets/Style/Settings.
    /// The app requires an Ambitious account: every signed-out attempt to reach
    /// the main window (menu items included) lands on the sign-in screen instead.
    func openMain(tab: MainTab = .home) {
        guard AmbitiousAuthManager.shared.isSignedIn else {
            openOnboarding(startStep: .signIn)
            return
        }
        MainWindowState.shared.tab = tab
        open(key: "main", title: "Prompter", size: NSSize(width: 960, height: 640)) {
            MainWindowView()
        }
    }

    func closeMain() {
        windows["main"]?.close()
    }

    func openDictionary() { openMain(tab: .dictionary) }
    func openStyle() { openMain(tab: .style) }
    func openInsights() { openMain(tab: .insights) }
    func openSettings() { openMain(tab: .settings) }
    func openSnippetsTab() { openMain(tab: .snippets) }

    func openSnippets() { openMain(tab: .snippets) }

    func openOnboarding(startStep: OnboardingStep = .welcome) {
        open(key: "onboarding", title: "Welcome to Prompter", size: NSSize(width: 680, height: 640), chromeless: true) {
            OnboardingView(startStep: startStep).environmentObject(ConfigStore.shared)
        }
    }

    func closeOnboarding() {
        windows["onboarding"]?.close()
    }
}
