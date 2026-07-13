import AppKit
import SwiftUI

enum HotkeyCaptureTarget: String, Identifiable {
    case dictation
    case prompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation hotkey"
        case .prompt: return "Prompt Mode hotkey"
        }
    }
}

/// Small modal recorder shared by Settings and onboarding. It saves as soon as
/// the user presses a non-modifier key or auxiliary mouse button, or releases a
/// modifier pressed by itself.
struct HotkeyRecorderSheet: View {
    let target: HotkeyCaptureTarget
    let onCapture: (HotkeyShortcut) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                Image(systemName: "computermouse")
            }
            .font(.system(size: 27))
            .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text(target.title).font(.title2.bold())
                Text("Press a key, key combination, or extra mouse button.")
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                    Text("Waiting for your shortcut…")
                        .font(.headline)
                }
                ShortcutCaptureView(
                    onCapture: { shortcut in
                        onCapture(shortcut)
                        dismiss()
                    },
                    onCancel: { dismiss() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 72)

            Text("Middle-click and extra gaming-mouse buttons are supported. Left and right click stay unchanged. Press Esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 430)
        .onAppear { DictationController.shared.hotkeySelectionActive = true }
        .onDisappear { DictationController.shared.hotkeySelectionActive = false }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (HotkeyShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((HotkeyShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private var pendingModifierKeyCode: UInt16?
    private var hasFinished = false
    private var mouseCaptureMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMouseCaptureMonitor()
            return
        }
        installMouseCaptureMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    deinit {
        removeMouseCaptureMonitor()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        captureKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        captureKeyDown(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !hasFinished,
              let flag = HotkeyShortcut.modifierFlag(for: event.keyCode) else { return }

        if event.modifierFlags.contains(flag) {
            // Wait for either a regular key (a combination such as ⌘K) or this
            // modifier's release (the modifier by itself).
            pendingModifierKeyCode = event.keyCode
        } else if pendingModifierKeyCode == event.keyCode {
            finish(HotkeyShortcut(keyCode: event.keyCode, modifiers: flag, isModifierOnly: true))
        }
    }

    private func captureKeyDown(_ event: NSEvent) {
        guard !hasFinished, !event.isARepeat else { return }
        if event.keyCode == 53 { // Esc is reserved for cancelling a recording.
            hasFinished = true
            onCancel?()
            return
        }

        pendingModifierKeyCode = nil
        let modifiers = event.modifierFlags.intersection(HotkeyShortcut.relevantModifiers)
        finish(HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    private func installMouseCaptureMonitor() {
        guard mouseCaptureMonitor == nil else { return }
        mouseCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, self.window != nil, !self.hasFinished else { return event }
            guard event.buttonNumber >= 2 else { return event }
            self.finish(HotkeyShortcut(mouseButtonNumber: event.buttonNumber))
            return nil
        }
    }

    private func removeMouseCaptureMonitor() {
        if let mouseCaptureMonitor { NSEvent.removeMonitor(mouseCaptureMonitor) }
        mouseCaptureMonitor = nil
    }

    private func finish(_ shortcut: HotkeyShortcut) {
        guard !hasFinished else { return }
        hasFinished = true
        onCapture?(shortcut)
    }
}
