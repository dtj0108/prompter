import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var updater = AppUpdater.shared
    @State private var micStatus = Recorder.micAuthorized()
    @State private var axStatus = AXIsProcessTrusted()
    @State private var inputMonStatus = CGPreflightListenEventAccess()
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Hotkeys") {
                Picker("Dictation", selection: $store.config.dictationHotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.display).tag(key.rawValue)
                    }
                }
                Picker("Prompt Mode", selection: $store.config.promptHotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.display).tag(key.rawValue)
                    }
                }
                Toggle("Tap for hands-free (tap again to finish)", isOn: $store.config.tapToLockEnabled)
                Text("Hold = push-to-talk: hold the key, speak, release to insert. Tap = hands-free: tap once, talk as long as you want, tap again when done. Esc cancels. Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.config.dictationHotkey == store.config.promptHotkey {
                    Text("⚠️ Both modes are on the same key — Prompt Mode will never trigger.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if store.config.dictationHotkey == HotkeyKey.fn.rawValue || store.config.promptHotkey == HotkeyKey.fn.rawValue {
                    Text("Using fn: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the system doesn't race Prompter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("AI cleanup") {
                Toggle("Clean up dictation with AI", isOn: $store.config.llmCleanupEnabled)
                Text("Off = raw transcript with dictionary corrections only.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("OpenRouter API key (sk-or-…)", text: $store.config.openRouterKey)
                Picker("Model", selection: $store.config.openRouterModel) {
                    ForEach(AIModelCatalog.choices) { choice in
                        Text("\(choice.name) — \(choice.detail)").tag(choice.id)
                    }
                    if AIModelCatalog.choice(for: store.config.openRouterModel) == nil {
                        Text("Custom — \(store.config.openRouterModel)").tag(store.config.openRouterModel)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Provider model ID", value: store.config.openRouterModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Use a custom OpenRouter model") {
                    TextField("Provider model ID", text: $store.config.openRouterModel)
                        .textFieldStyle(.roundedBorder)
                }
                Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .font(.caption)
                Text("GPT-5.6 Luna is the smallest, fastest GPT-5.6 tier. “:free” models may be request-limited and may let the provider train on your text.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Backend in use", value: LLMClient.shared.backendDescription)
                HStack {
                    Button(testing ? "Testing…" : "Test AI backend") {
                        runBackendTest()
                    }
                    .disabled(testing)
                    if !testResult.isEmpty {
                        Text(testResult).font(.caption)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    }
                }
                DisclosureGroup("Fallback: Claude CLI (used when no OpenRouter key)") {
                    TextField("Cleanup model", text: $store.config.cleanupModel)
                    TextField("Prompt Mode model", text: $store.config.promptModel)
                    TextField("claude CLI path (blank = auto-detect)", text: $store.config.claudeCLIPath)
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone", value: micStatus ? "✓ Granted" : "Not granted")
                LabeledContent("Accessibility", value: axStatus ? "✓ Granted" : "Not granted")
                LabeledContent("Input Monitoring", value: inputMonStatus ? "✓ Granted" : "Not needed unless hotkeys don't respond")
                HStack {
                    Button("Request permissions") {
                        Task {
                            _ = await Recorder.requestMicAccess()
                            let options = ["AXTrustedCheckOptionPrompt" as CFString as String: true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                            refreshPermissions()
                        }
                    }
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Refresh") { refreshPermissions() }
                }
                if !inputMonStatus {
                    Button("Hotkeys not responding? Request Input Monitoring") {
                        _ = CGRequestListenEventAccess()
                        refreshPermissions()
                    }
                }
                Text("Microphone = hearing you. Accessibility = watching for your hotkey, pressing ⌘V for you, and reading window titles.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Setup Assistant…") {
                    WindowRouter.shared.openOnboarding()
                }
            }

            Section("Behavior") {
                Toggle("Play sounds", isOn: $store.config.soundsEnabled)
                Toggle("Show bar at bottom of screen", isOn: Binding(
                    get: { store.config.showIdleIndicator },
                    set: { newValue in
                        store.config.showIdleIndicator = newValue
                        HUD.shared.applyIdleIndicatorSetting()
                    }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { store.config.launchAtLogin },
                    set: { newValue in
                        store.config.launchAtLogin = newValue
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.write("login item error: \(error)")
                        }
                    }
                ))
                Stepper("Hold threshold: \(store.config.holdThresholdMs) ms", value: $store.config.holdThresholdMs, in: 80...500, step: 20)
                Text("How long you must hold the key before recording starts (filters accidental taps).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Prompt Mode") {
                Button("Edit the Prompt Mode instructions…") {
                    Prompts.ensurePromptModeFileExists()
                    NSWorkspace.shared.open(Paths.promptModeFile)
                }
                Text("The meta-prompt that turns your rambling into a well-engineered prompt. It's a text file — edit freely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Button {
                    updater.performPrimaryAction()
                } label: {
                    Label(updateButtonTitle, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(updateButtonDisabled)

                if !updateStatusText.isEmpty {
                    Text(updateStatusText)
                        .font(.caption)
                        .foregroundStyle(updateFailed ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onAppear {
            refreshPermissions()
            // Always re-check on open (stale "up to date" from launch otherwise
            // hides releases published while the app was running) — but don't
            // clobber an update that's already found or installing.
            switch updater.state {
            case .available, .downloading: break
            default: updater.checkForUpdates()
            }
        }
    }

    private func refreshPermissions() {
        micStatus = Recorder.micAuthorized()
        axStatus = AXIsProcessTrusted()
        inputMonStatus = CGPreflightListenEventAccess()
    }

    private func runBackendTest() {
        testing = true
        testResult = ""
        Task {
            do {
                let reply = try await LLMClient.shared.complete(
                    system: "Reply with exactly: OK",
                    user: "Say OK.",
                    model: ConfigStore.shared.config.cleanupModel,
                    timeout: 60
                )
                await MainActor.run {
                    testResult = reply.text.contains("OK") ? "✓ Working" : "✓ Replied: \(reply.text.prefix(40))"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }

    private var updateButtonTitle: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .available(let update): return "Install Update \(update.version)"
        case .downloading: return "Downloading…"
        default: return "Update Now"
        }
    }

    private var updateButtonDisabled: Bool {
        switch updater.state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var updateStatusText: String {
        switch updater.state {
        case .idle: return ""
        case .checking: return "Checking GitHub Releases…"
        case .upToDate: return "Prompter \(updater.currentVersion) is up to date."
        case .available(let update):
            return update.notes.isEmpty ? "Version \(update.version) is available." : update.notes
        case .downloading: return "Downloading and verifying the update…"
        case .failed(let message): return message
        }
    }

    private var updateFailed: Bool {
        if case .failed = updater.state { return true }
        return false
    }
}
