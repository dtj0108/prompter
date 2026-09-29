import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var auth = AmbitiousAuthManager.shared
    @ObservedObject private var updater = AppUpdater.shared
    @State private var micStatus = Recorder.micAuthorized()
    @State private var axStatus = AXIsProcessTrusted()
    @State private var inputMonStatus = CGPreflightListenEventAccess()
    @State private var testResult = ""
    @State private var testing = false
    private struct HotkeyEditRequest: Identifiable {
        let id = UUID()
        let target: HotkeyCaptureTarget
        var index: Int?
    }
    @State private var hotkeyEditRequest: HotkeyEditRequest?
    @State private var hotkeyError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Ambitious account") {
                if let identity = auth.identity {
                    LabeledContent("Signed in", value: identity.email ?? "Ambitious member")
                    Text("This sign-in only confirms your identity. Its tokens cannot read or post Ambitious content, and your saved sign-in does not need a network check before dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(auth.activity == .refreshing ? "Checking…" : "Check account") {
                            auth.refreshNow()
                        }
                        .disabled(auth.activity == .refreshing || auth.activity == .signOutPending)
                        .clickCursor()
                        Button("Sign out") { auth.signOut() }
                            .disabled(auth.activity == .signOutPending)
                            .clickCursor()
                    }
                    Text("You can also remove Ambitious Prompts at Ambitious → Settings → Connected Apps.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("A free Ambitious account is required for dictation and Prompt Mode.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(auth.activity == .signingIn ? "Signing in…" : "Sign in with Ambitious") {
                        auth.signIn()
                    }
                    .disabled(auth.activity == .signingIn || !auth.isActivated)
                    .clickCursor()
                }
                if let message = auth.errorMessage {
                    Text(message).font(.caption)
                        .foregroundStyle(auth.activity == .signOutPending ? Color.secondary : Color.orange)
                }
            }

            Section("API Keys") {
                APIKeyField(title: "OpenAI", placeholder: "sk-proj-…", key: $store.config.openAIKey,
                            provider: .openAI, required: true)
                    .padding(.vertical, 4)
                HStack {
                    Text("Powers GPT Live Transcribe (\(OpenAIRealtimeTranscriber.defaultModel)). Your audio streams directly to OpenAI.")
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://platform.openai.com/settings/organization/api-keys")!)
                        .foregroundStyle(AmbitiousDesign.brandPrimary)
                        .clickCursor()
                }
                .font(.caption).foregroundStyle(.secondary)
                APIKeyField(title: "OpenRouter", placeholder: "sk-or-…", key: $store.config.openRouterKey,
                            provider: .openRouter)
                    .padding(.vertical, 4)
                HStack {
                    Text("Powers AI cleanup and Prompt Mode. Skip it to use the claude CLI or Dictionary corrections.")
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        .foregroundStyle(AmbitiousDesign.brandPrimary)
                        .clickCursor()
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("Keys are stored only on this Mac. Test sends no audio and costs nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hotkeys") {
                hotkeyGroup("Dictation", target: .dictation)
                hotkeyGroup("Prompt Mode", target: .prompt)
                if let hotkeyError {
                    Text(hotkeyError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Tap for hands-free (tap again to finish)", isOn: $store.config.tapToLockEnabled).clickCursor()
                Text("Add as many shortcuts as you want. Use a key, key combination, middle-click, or extra mouse button. Hold and release the same shortcut for push-to-talk. In hands-free mode, any shortcut for that mode finishes recording. Esc cancels. Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.config.conflictingHotkeys.isEmpty {
                    Text("A shortcut is assigned to both modes. Dictation takes priority; edit one of the duplicate assignments.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if (store.config.hotkeyValues(for: .dictate) + store.config.hotkeyValues(for: .prompt)).contains(HotkeyKey.fn.rawValue) {
                    Text("Using fn: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the system doesn't race Ambitious Prompts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("AI models") {
                LabeledContent("Transcription model", value: OpenAIRealtimeTranscriber.defaultModel)

                Toggle("Clean up dictation with AI", isOn: $store.config.llmCleanupEnabled).clickCursor()
                Text("Off = raw transcript with dictionary corrections only.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Cleanup model", selection: $store.config.openRouterCleanupModel) {
                    ForEach(AIModelCatalog.choices) { choice in
                        Text("\(choice.name) — \(choice.detail)").tag(choice.id)
                    }
                    if AIModelCatalog.choice(for: store.config.openRouterCleanupModel) == nil {
                        Text("Custom — \(store.config.openRouterCleanupModel)").tag(store.config.openRouterCleanupModel)
                    }
                }
                .pickerStyle(.menu)
                .clickCursor()
                Picker("Prompt Mode model", selection: $store.config.openRouterModel) {
                    ForEach(AIModelCatalog.choices) { choice in
                        Text("\(choice.name) — \(choice.detail)").tag(choice.id)
                    }
                    if AIModelCatalog.choice(for: store.config.openRouterModel) == nil {
                        Text("Custom — \(store.config.openRouterModel)").tag(store.config.openRouterModel)
                    }
                }
                .pickerStyle(.menu)
                .clickCursor()
                Text("OpenRouter is optional and powers text cleanup and Prompt Mode. Gemini Flash Lite is the fast, inexpensive cleanup and Prompt Mode default.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Use custom OpenRouter model IDs") {
                    TextField("Cleanup model ID", text: $store.config.openRouterCleanupModel)
                        .textFieldStyle(.roundedBorder)
                    TextField("Prompt Mode model ID", text: $store.config.openRouterModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("“:free” models may be request-limited and may let the provider train on your text.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Cleanup / Prompt Mode", value: LLMClient.shared.backendDescription)
                HStack {
                    Button(testing ? "Testing…" : "Test AI backend") {
                        runBackendTest()
                    }
                    .disabled(testing)
                    .clickCursor()
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
                    .clickCursor()
                    Button("Open System Settings") {
                        SystemSettingsPrivacyPane.accessibility.open()
                    }
                    .clickCursor()
                    Button("Refresh") { refreshPermissions() }.clickCursor()
                }
                if !inputMonStatus {
                    Button("Hotkeys not responding? Request Input Monitoring") {
                        _ = CGRequestListenEventAccess()
                        refreshPermissions()
                    }
                    .clickCursor()
                }
                Text("Microphone = hearing you. Accessibility = watching for your hotkey, pressing ⌘V for you, and reading window titles.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Setup Assistant…") {
                    WindowRouter.shared.openOnboarding()
                }
                .clickCursor()
            }

            Section("Behavior") {
                Toggle("Type live while I speak", isOn: $store.config.liveTypingEnabled).clickCursor()
                Text("Show words in the focused text box during dictation. AI cleanup updates only those words when you finish. Moving the cursor, editing, or changing focus stops live updates and copies the finished text. Unsupported text boxes use paste when you finish. Prompt Mode always inserts at the end.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Focus on my voice", isOn: $store.config.voiceIsolationEnabled).clickCursor()
                Text("Apple's on-device voice isolation: keys on the person speaking at the Mac and suppresses background noise and other voices. For even stronger isolation, pick “Voice Isolation” under Mic Mode in Control Center while dictating.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play sounds", isOn: $store.config.soundsEnabled).clickCursor()
                Toggle("Show bar at bottom of screen", isOn: Binding(
                    get: { store.config.showIdleIndicator },
                    set: { newValue in
                        store.config.showIdleIndicator = newValue
                        HUD.shared.applyIdleIndicatorSetting()
                    }
                ))
                .clickCursor()
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
                .clickCursor()
                Stepper("Hold threshold: \(store.config.holdThresholdMs) ms", value: $store.config.holdThresholdMs, in: 80...500, step: 20).clickCursor()
                Text("How long you must hold the key before recording starts (filters accidental taps).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Prompt Mode") {
                Button("Edit the Prompt Mode instructions…") {
                    Prompts.ensurePromptModeFileExists()
                    NSWorkspace.shared.open(Paths.promptModeFile)
                }
                .clickCursor()
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
                .clickCursor()

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
        .sheet(item: $hotkeyEditRequest) { request in
            HotkeyRecorderSheet(target: request.target) { shortcut in
                hotkeyError = store.config.setHotkey(shortcut, for: request.target.mode, replacing: request.index)
            }
        }
    }

    private func hotkeyGroup(_ title: String, target: HotkeyCaptureTarget) -> some View {
        let values = store.config.hotkeyValues(for: target.mode)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                LabeledContent("Shortcut \(index + 1)") {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(HotkeyKey.allCases) { key in
                                Button {
                                    hotkeyError = store.config.setHotkey(
                                        HotkeyShortcut(preset: key), for: target.mode, replacing: index
                                    )
                                } label: {
                                    if value == key.rawValue {
                                        Label(key.display, systemImage: "checkmark")
                                    } else {
                                        Text(key.display)
                                    }
                                }
                                .disabled(store.config.hotkeyConflict(HotkeyShortcut(preset: key), for: target.mode, replacing: index) != nil)
                            }
                        } label: {
                            Text(HotkeyShortcut.display(for: value, fallback: target == .dictation ? .rightOption : .rightCommand))
                        }
                        .clickCursor()
                        Button("Custom…") {
                            hotkeyError = nil
                            hotkeyEditRequest = HotkeyEditRequest(target: target, index: index)
                        }
                        .buttonStyle(.bordered).controlSize(.small).clickCursor()
                        Button {
                            store.config.removeHotkey(at: index, for: target.mode)
                            hotkeyError = nil
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(values.count == 1)
                        .accessibilityLabel("Remove \(title) shortcut \(index + 1)")
                        .help(values.count == 1 ? "Keep at least one shortcut for each mode" : "Remove shortcut")
                        .clickCursor()
                    }
                }
            }
            Button {
                hotkeyError = nil
                hotkeyEditRequest = HotkeyEditRequest(target: target)
            } label: {
                Label("Add shortcut…", systemImage: "plus")
            }
            .accessibilityLabel("Add \(title) shortcut")
            .buttonStyle(.bordered).controlSize(.small).clickCursor()
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
        case .upToDate: return "Ambitious Prompts \(updater.currentVersion) is up to date."
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
