import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var micStatus = Recorder.micAuthorized()
    @State private var axStatus = AXIsProcessTrusted()
    @State private var inputMonStatus = CGPreflightListenEventAccess()
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Hotkeys (hold to talk, release to insert)") {
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
                Toggle("Clean up dictation with Claude", isOn: $store.config.llmCleanupEnabled)
                Text("Off = raw transcript with dictionary corrections only.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Cleanup model", text: $store.config.cleanupModel)
                TextField("Prompt Mode model", text: $store.config.promptModel)
                SecureField("Anthropic API key (optional — faster)", text: $store.config.apiKey)
                TextField("claude CLI path (blank = auto-detect)", text: $store.config.claudeCLIPath)
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
        .onAppear { refreshPermissions() }
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
                    testResult = reply.contains("OK") ? "✓ Working" : "✓ Replied: \(reply.prefix(40))"
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
}
