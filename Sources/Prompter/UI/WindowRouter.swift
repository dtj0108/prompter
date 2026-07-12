import AppKit
import SwiftUI

final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()

    private var windows: [String: NSWindow] = [:]

    func open<Content: View>(key: String, title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
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
    func openMain(tab: MainTab = .home) {
        MainWindowState.shared.tab = tab
        open(key: "main", title: "Prompter", size: NSSize(width: 960, height: 640)) {
            MainWindowView()
        }
    }

    func openDictionary() { openMain(tab: .dictionary) }
    func openStyle() { openMain(tab: .style) }
    func openInsights() { openMain(tab: .insights) }
    func openSettings() { openMain(tab: .settings) }
    func openSnippetsTab() { openMain(tab: .snippets) }

    func openSnippets() { openMain(tab: .snippets) }

    func openOnboarding() {
        open(key: "onboarding", title: "Welcome to Prompter", size: NSSize(width: 560, height: 540)) {
            OnboardingView().environmentObject(ConfigStore.shared)
        }
    }

    func closeOnboarding() {
        windows["onboarding"]?.close()
    }
}
