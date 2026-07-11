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

    func openDictionary() {
        open(key: "dictionary", title: "Dictionary", size: NSSize(width: 620, height: 480)) {
            DictionaryView().environmentObject(DictionaryStore.shared)
        }
    }

    func openStyle() {
        open(key: "style", title: "Style", size: NSSize(width: 640, height: 640)) {
            StyleView().environmentObject(StyleStore.shared)
        }
    }

    func openInsights() {
        InsightsStore.shared.reload()
        open(key: "insights", title: "Insights", size: NSSize(width: 680, height: 620)) {
            InsightsView().environmentObject(InsightsStore.shared)
        }
    }

    func openSettings() {
        open(key: "settings", title: "Settings", size: NSSize(width: 560, height: 620)) {
            SettingsView().environmentObject(ConfigStore.shared)
        }
    }
}
