import AppKit
import SwiftUI

enum HUDState: Equatable {
    case hidden
    case listening(DictationMode)
    case processing(DictationMode)
    case success(String)
    case failure(String)
}

final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
}

/// Panel that can never steal keyboard focus from the app being dictated into.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HUD {
    static let shared = HUD()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        panel = p
        return p
    }

    func show(_ state: HUDState) {
        DispatchQueue.main.async {
            self.hideWork?.cancel()
            self.model.state = state
            let panel = self.ensurePanel()
            self.position(panel)
            panel.orderFrontRegardless()
        }
    }

    func flash(_ state: HUDState, for seconds: Double = 1.6) {
        DispatchQueue.main.async {
            self.hideWork?.cancel()
            self.model.state = state
            let panel = self.ensurePanel()
            self.position(panel)
            panel.orderFrontRegardless()
            let work = DispatchWorkItem { self.hide() }
            self.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.hideWork?.cancel()
            self.model.state = .hidden
            self.panel?.orderOut(nil)
        }
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer()
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            Spacer().frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .listening(let mode):
            HStack(spacing: 10) {
                Circle()
                    .fill(mode == .prompt ? Color.purple : Color.red)
                    .frame(width: 11, height: 11)
                    .scaleEffect(pulse ? 1.25 : 0.8)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
                Text(mode == .prompt ? "Listening — Prompt Mode" : "Listening…")
                    .font(.system(size: 13, weight: .medium))
                if mode == .prompt {
                    Text("PROMPT")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        case .processing(let mode):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(mode == .prompt ? "Crafting your prompt…" : "Polishing…")
                    .font(.system(size: 13, weight: .medium))
            }
        case .success(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.system(size: 13, weight: .medium))
            }
        case .failure(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.system(size: 13, weight: .medium))
            }
        }
    }
}
