import SwiftUI
import AppKit
import AVFoundation

enum MainTab: String, CaseIterable, Identifiable {
    case home, insights, dictionary, snippets, style, promptMode, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .promptMode: return "Prompt Mode"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .dictionary: return "character.book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .promptMode: return "wand.and.stars"
        case .settings: return "gearshape"
        }
    }
}

/// Shared so the menu bar (and router) can steer the open window to a tab.
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()
    @Published var tab: MainTab = .home
}

struct MainWindowView: View {
    @ObservedObject var state = MainWindowState.shared

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(MainTab.allCases) { tab in
                        SidebarItem(tab: tab, selected: state.tab == tab) {
                            state.tab = tab
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            // No app-icon header and no collapse-sidebar toolbar button — the
            // sidebar is permanent and the content starts at the top.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.tab {
        case .home:
            HomeView()
                .environmentObject(ConfigStore.shared)
                .environmentObject(InsightsStore.shared)
        case .insights:
            InsightsView()
                .environmentObject(InsightsStore.shared)
                .onAppear { InsightsStore.shared.reload() }
        case .dictionary:
            DictionaryView()
                .environmentObject(DictionaryStore.shared)
        case .snippets:
            SnippetsView()
                .environmentObject(SnippetStore.shared)
        case .style:
            StyleView()
                .environmentObject(StyleStore.shared)
        case .promptMode:
            PromptModeView()
                .environmentObject(ConfigStore.shared)
        case .settings:
            SettingsView()
                .environmentObject(ConfigStore.shared)
        }
    }
}

/// Custom sidebar row: full control of hover highlight, selection fill,
/// and the pointing-hand cursor (List's sidebar style eats all of these).
private struct SidebarItem: View {
    let tab: MainTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @State private var cursorPushed = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tab.symbol)
                .frame(width: 20)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(tab.label)
                .foregroundStyle(.primary.opacity(selected ? 1 : 0.85))
            Spacer(minLength: 0)
        }
        .font(.body.weight(selected ? .medium : .regular))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected
                      ? Color.primary.opacity(0.11)
                      : Color.primary.opacity(hovered ? 0.06 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture(perform: action)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
            if inside, !cursorPushed {
                NSCursor.pointingHand.push()
                cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var insights: InsightsStore
    @State private var micGranted = Recorder.micAuthorized()
    @State private var axGranted = AXIsProcessTrusted()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.largeTitle.bold())
                    Text("Talk instead of type — anywhere on your Mac.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                // Hotkey cards (click → Settings)
                HStack(spacing: 12) {
                    hotkeyCard(
                        symbol: "mic.fill",
                        tint: Color(red: 1.0, green: 0.27, blue: 0.23),
                        title: "Dictate",
                        key: dictationKeyName,
                        detail: "Hold and talk, or tap once for hands-free — tap again to finish."
                    )
                    hotkeyCard(
                        symbol: "wand.and.stars",
                        tint: .blue,
                        title: "Prompt Mode",
                        key: promptKeyName,
                        detail: "Ramble what you want an AI to do — out comes an engineered prompt."
                    )
                }

                // Today (click → Insights)
                HStack(spacing: 12) {
                    statCard("Today", "\(insights.todayWords)", "words")
                    statCard("Streak", "\(insights.streakDays)", insights.streakDays == 1 ? "day" : "days")
                    statCard("All time", insights.totalWords.formatted(), "words")
                }

                // Status
                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow(ok: micGranted, text: micGranted ? "Microphone granted" : "Microphone not granted")
                        statusRow(ok: axGranted, text: axGranted ? "Accessibility granted" : "Accessibility not granted")
                        statusRow(ok: !backendMissing, text: "AI backend: \(LLMClient.shared.backendDescription)")
                        if !micGranted || !axGranted || backendMissing {
                            Button("Open Setup Assistant") {
                                WindowRouter.shared.openOnboarding()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                historySection
            }
            .padding(24)
        }
        .onAppear { insights.reload() }
        .onReceive(timer) { _ in
            micGranted = Recorder.micAuthorized()
            axGranted = AXIsProcessTrusted()
        }
    }

    private var backendMissing: Bool {
        LLMClient.shared.backendDescription == "none found"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var dictationKeyName: String {
        HotkeyKey(rawValue: config.config.dictationHotkey)?.shortDisplay ?? "Right ⌥"
    }
    private var promptKeyName: String {
        HotkeyKey(rawValue: config.config.promptHotkey)?.shortDisplay ?? "Right ⌘"
    }

    private func hotkeyCard(symbol: String, tint: Color, title: String, key: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.headline)
                Spacer()
                Text(key)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverCard()
        .onTapGesture { MainWindowState.shared.tab = .settings }
        .help("Change hotkeys in Settings")
    }

    private func statCard(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.bold))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverCard()
        .onTapGesture { MainWindowState.shared.tab = .insights }
        .help("See full Insights")
    }

    private func statusRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text).font(.callout)
        }
    }

    // MARK: History

    /// Every dictation, newest first. Events logged before text capture existed
    /// carry no text and are skipped.
    private var historyEvents: [InsightEvent] {
        insights.events
            .filter { !$0.finalText.isEmpty || !$0.rawText.isEmpty }
            .sorted { $0.ts > $1.ts }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.title3.bold())
            if historyEvents.isEmpty {
                Text("Everything you dictate will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(historyEvents) { event in
                        HistoryRow(event: event)
                    }
                }
            }
        }
    }
}

// MARK: - History row

/// One past dictation. Collapsed: a two-line preview of what was pasted.
/// Expanded: the full text — and for prompt mode, "You said" vs "Prompt"
/// so the transformation is visible.
private struct HistoryRow: View {
    let event: InsightEvent
    @State private var expanded = false
    @State private var copied = false
    @State private var hovered = false

    private var isPrompt: Bool { event.mode == DictationMode.prompt.rawValue }
    /// The pasted text; raw transcript is the fallback for LLM-skipped events.
    private var outputText: String { event.finalText.isEmpty ? event.rawText : event.finalText }
    private var hasDistinctRaw: Bool {
        !event.rawText.isEmpty && event.rawText != outputText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isPrompt ? "wand.and.stars" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(isPrompt ? Color.blue : Color(red: 1.0, green: 0.27, blue: 0.23))
                    .frame(width: 16)
                Text(isPrompt ? "Prompt" : "Dictation")
                    .font(.caption.weight(.semibold))
                if !event.app.isEmpty {
                    Text("→ \(event.app)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.timestamp(event.ts))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outputText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovered || copied ? 1 : 0)
                .help("Copy")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }

            if expanded {
                if isPrompt && hasDistinctRaw {
                    // What was said vs the prompt that came out of it.
                    textBlock(label: "You said", text: event.rawText, dimmed: true)
                    textBlock(label: "Prompt", text: outputText, dimmed: false)
                } else {
                    if hasDistinctRaw {
                        textBlock(label: "You said", text: event.rawText, dimmed: true)
                    }
                    textBlock(label: hasDistinctRaw ? "Result" : nil, text: outputText, dimmed: false)
                }
            } else {
                Text(outputText)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(hovered ? 0.1 : 0.07))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
    }

    @ViewBuilder
    private func textBlock(label: String?, text: String, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let df = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            df.dateStyle = .none
            df.timeStyle = .short
        } else {
            df.dateStyle = .medium
            df.timeStyle = .short
        }
        return df.string(from: date)
    }
}
