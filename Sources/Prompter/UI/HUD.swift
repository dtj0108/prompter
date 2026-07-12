import AppKit
import SwiftUI

enum HUDState: Equatable {
    case idle
    case listening(DictationMode, handsFree: Bool = false)
    case processing(DictationMode)
    case success(String)
    case failure(String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

final class HUDModel: ObservableObject {
    static let barCount = 26
    @Published var state: HUDState = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: HUDModel.barCount)

    func pushLevel(_ value: CGFloat) {
        var next = levels
        next.removeFirst()
        next.append(value)
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// Panel that can never steal keyboard focus from the app being dictated into.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Wispr-style indicator: a small bar resting at the bottom-center of the screen
/// that expands into a waveform pill while listening.
final class HUD {
    static let shared = HUD()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var revertWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    /// Call once at launch: puts the resting bar on screen (if enabled).
    func start() {
        DispatchQueue.main.async {
            self.applyVisibility()
            if self.screenObserver == nil {
                self.screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, let panel = self.panel else { return }
                    self.position(panel)
                }
            }
        }
    }

    func show(_ state: HUDState) {
        DispatchQueue.main.async {
            self.revertWork?.cancel()
            if case .listening = state { self.model.resetLevels() }
            self.model.state = state
            let panel = self.ensurePanel()
            self.position(panel) // jump to the screen the user is working on
            panel.orderFrontRegardless()
        }
    }

    func flash(_ state: HUDState, for seconds: Double = 1.6) {
        DispatchQueue.main.async {
            self.revertWork?.cancel()
            self.model.state = state
            let panel = self.ensurePanel()
            self.position(panel)
            panel.orderFrontRegardless()
            let work = DispatchWorkItem { self.backToIdle() }
            self.revertWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// Collapse back to the resting bottom-center bar.
    func hide() {
        DispatchQueue.main.async { self.backToIdle() }
    }

    /// Live mic level from the recorder, 0…1. Safe from any thread.
    func level(_ value: Float) {
        DispatchQueue.main.async {
            guard case .listening = self.model.state else { return }
            self.model.pushLevel(CGFloat(min(max(value, 0), 1)))
        }
    }

    /// Re-apply after the "show resting indicator" setting changes.
    func applyIdleIndicatorSetting() {
        DispatchQueue.main.async { self.applyVisibility() }
    }

    private func backToIdle() {
        revertWork?.cancel()
        model.state = .idle
        model.resetLevels()
        applyVisibility()
    }

    private func applyVisibility() {
        let panel = ensurePanel()
        if model.state.isActive || ConfigStore.shared.config.showIdleIndicator {
            position(panel)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 76),
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        panel = p
        return p
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        // visibleFrame.minY sits just above the Dock when it's shown and at the true
        // bottom edge when it's hidden — flush to the bottom like Wispr's bar.
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 2))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var isIdle: Bool { !model.state.isActive }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack { content }
                .padding(.horizontal, isIdle ? 0 : 16)
                .padding(.vertical, isIdle ? 0 : 11)
                .frame(width: isIdle ? 64 : nil, height: isIdle ? 9 : nil)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(isIdle ? 0.5 : 0.82))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(isIdle ? 0.2 : 0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(isIdle ? 0.2 : 0.35), radius: isIdle ? 4 : 14, y: isIdle ? 1 : 4)
                )
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()

        case .listening(let mode, let handsFree):
            HStack(spacing: 10) {
                Circle()
                    .fill(accent(mode))
                    .frame(width: 8, height: 8)
                Waveform(levels: model.levels, tint: .white)
                    .frame(width: 150, height: 26)
                if handsFree {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 8))
                        Text("tap key to finish").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                if mode == .prompt { badge("PROMPT") }
            }

        case .processing(let mode):
            HStack(spacing: 10) {
                ProcessingDots(color: accent(mode))
                Text(mode == .prompt ? "Crafting your prompt…" : "Polishing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }

        case .success(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }

        case .failure(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    private func accent(_ mode: DictationMode) -> Color {
        mode == .prompt ? .blue : Color(red: 1.0, green: 0.27, blue: 0.23)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(tint.opacity(0.5 + 0.5 * levels[i]))
                    .frame(width: 3, height: 3 + levels[i] * 22)
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
    }
}

private struct ProcessingDots: View {
    let color: Color
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase ? 1.0 : 0.5)
                    .opacity(phase ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}
