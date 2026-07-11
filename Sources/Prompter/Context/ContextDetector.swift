import AppKit
import ApplicationServices

struct FrontContext {
    var appName: String
    var bundleId: String
    var pid: pid_t
    var windowTitle: String
    var style: ContextStyle

    static let unknown = FrontContext(
        appName: "",
        bundleId: "",
        pid: 0,
        windowTitle: "",
        style: StyleConfig.default.contexts.last!
    )
}

enum ContextDetector {

    /// Snapshot the frontmost app + focused window title and resolve which style context applies.
    /// Call this at hotkey-press time, before the HUD appears.
    static func capture() -> FrontContext {
        let style = StyleStore.shared.style
        let fallback = style.contexts.first(where: { $0.id == "other" }) ?? style.contexts.last ?? StyleConfig.default.contexts.last!

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FrontContext(appName: "", bundleId: "", pid: 0, windowTitle: "", style: fallback)
        }
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        let title = focusedWindowTitle(pid: app.processIdentifier) ?? ""

        let matched = match(bundleId: bundleId, title: title, contexts: style.contexts) ?? fallback
        return FrontContext(appName: name, bundleId: bundleId, pid: app.processIdentifier, windowTitle: title, style: matched)
    }

    static func match(bundleId: String, title: String, contexts: [ContextStyle]) -> ContextStyle? {
        let lowerBundle = bundleId.lowercased()
        let lowerTitle = title.lowercased()

        // Bundle-id match wins over title keywords; "other" only as fallback.
        for ctx in contexts where ctx.id != "other" {
            for id in ctx.appBundleIds where !id.isEmpty && lowerBundle == id.lowercased() {
                return ctx
            }
        }
        if !lowerTitle.isEmpty {
            for ctx in contexts where ctx.id != "other" {
                for keyword in ctx.titleKeywords where !keyword.isEmpty && lowerTitle.contains(keyword.lowercased()) {
                    return ctx
                }
            }
        }
        return nil
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // Runs synchronously on the main thread at hotkey time — a hung target app
        // must not be able to stall us for the default multi-second AX timeout.
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        let windowElement = win as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
