import SwiftUI
import AVFoundation

enum MainTab: String, CaseIterable, Identifiable {
    case home, insights, dictionary, snippets, style, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
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
            List(MainTab.allCases, selection: Binding(
                get: { state.tab },
                set: { state.tab = $0 ?? .home }
            )) { tab in
                Label(tab.label, systemImage: tab.symbol).tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.linearGradient(
                            colors: [Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.22, green: 0.19, blue: 0.64)],
                            startPoint: .top, endPoint: .bottom))
                    Text("Prompter").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
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
        case .settings:
            SettingsView()
                .environmentObject(ConfigStore.shared)
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

                // Hotkey cards
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
                        tint: .purple,
                        title: "Prompt Mode",
                        key: promptKeyName,
                        detail: "Ramble what you want an AI to do — out comes an engineered prompt."
                    )
                }

                // Today
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statCard(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.bold))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text).font(.callout)
        }
    }
}
