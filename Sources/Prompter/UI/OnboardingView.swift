import SwiftUI
import AVFoundation

/// First-run setup assistant: walks through every macOS permission and choice the
/// app needs, with live status checks. Reopenable from the Prompter app menu.
struct OnboardingView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var step: Int

    /// Jump straight to a step — used when a permission was lost (e.g. after an
    /// app update reset TCC) and the assistant reopens on the broken step.
    init(startStep: Int = 0) {
        _step = State(initialValue: min(max(startStep, 0), 6))
    }
    @State private var micGranted = Recorder.micAuthorized()
    @State private var axGranted = AXIsProcessTrusted()
    @State private var testResult = ""
    @State private var testing = false
    @State private var practiceText = ""

    @State private var keyMonitor: Any?
    @State private var hotkeyCaptureTarget: HotkeyCaptureTarget?

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let stepCount = 7

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step < stepCount - 1 {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") {
                        store.config.onboardingDone = true
                        WindowRouter.shared.closeOnboarding()
                        WindowRouter.shared.openMain()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
        .onReceive(timer) { _ in
            micGranted = Recorder.micAuthorized()
            axGranted = AXIsProcessTrusted()
        }
        .onAppear { updateKeyCapture(for: step) }
        .onChange(of: step) { _, newStep in updateKeyCapture(for: newStep) }
        .onDisappear { updateKeyCapture(for: -1) }
        .sheet(item: $hotkeyCaptureTarget, onDismiss: {
            updateKeyCapture(for: step)
        }) { target in
            HotkeyRecorderSheet(target: target) { shortcut in
                switch target {
                case .dictation:
                    store.config.dictationHotkey = shortcut.storedValue
                case .prompt:
                    store.config.promptHotkey = shortcut.storedValue
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // AppDelegate reopens directly on steps 1 (mic) and 2 (accessibility)
        // when a permission is lost — keep those indices stable.
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibility
        case 3: dictationKeyStep
        case 4: promptKeyStep
        case 5: aiEngine
        default: tryIt
        }
    }

    // MARK: Step 1 — Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("👋", "Welcome to Prompter",
                   "Talk instead of type — anywhere on your Mac. Your voice is transcribed on this Mac (never uploaded), cleaned up by AI, and typed right where your cursor is.")

            VStack(alignment: .leading, spacing: 12) {
                bullet("hand.tap.fill", "\(dictationKeyName): hold and talk, release to insert. Or TAP it once for hands-free — talk as long as you want, tap again when done.")
                bullet("wand.and.stars", "\(promptKeyName): same thing, but your rambling comes out as a well-engineered AI prompt.")
                bullet("escape", "Esc cancels a recording at any point.")
                bullet("book.closed.fill", "Dictionary teaches it your words. Style controls your tone per app. Snippets expand phrases like “my email address”.")
            }
            .padding(.top, 4)

            Text("The next steps set up the two macOS permissions Prompter needs.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 2 — Microphone

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("🎤", "Allow the microphone",
                   "So Prompter can hear you while you hold the hotkey. Audio is processed entirely on this Mac by Apple's speech engine — nothing is recorded to disk or uploaded.")

            statusRow(granted: micGranted, label: micGranted ? "Microphone access granted" : "Microphone access needed")

            if !micGranted {
                Button("Allow Microphone") { requestMic() }
                .buttonStyle(.borderedProminent)
                Text("macOS will show a dialog — click “Allow”. If no dialog appears (it was denied before), open System Settings → Privacy & Security → Microphone and switch Prompter on.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open System Settings → Microphone") {
                    openPrivacyPane("Privacy_Microphone")
                }
            }
        }
        .onAppear { if !micGranted { requestMic() } }
    }

    private func requestMic() {
        Task { _ = await Recorder.requestMicAccess(); micGranted = Recorder.micAuthorized() }
    }

    // MARK: Step 3 — Accessibility

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("🔑", "Allow Accessibility",
                   "This is what lets Prompter notice your hotkey in any app, press ⌘V for you to insert the text, and see which app you're in so it can match your tone.")

            statusRow(granted: axGranted, label: axGranted ? "Accessibility granted" : "Accessibility needed")

            if !axGranted {
                Button("Grant Accessibility") { resetAndPromptAccessibility() }
                .buttonStyle(.borderedProminent)
                Text("In the dialog, click “Open System Settings”, then turn ON the switch next to Prompter in the Accessibility list. This screen updates by itself once it's on.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open System Settings → Accessibility") {
                    openPrivacyPane("Privacy_Accessibility")
                }
            } else {
                Text("One more macOS dialog may appear the very first time text is inserted (“Prompter would like to paste”) — choose “Always Allow”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { if !axGranted { resetAndPromptAccessibility() } }
    }

    /// A reinstalled/re-signed binary invalidates the existing Accessibility grant:
    /// System Settings still shows Prompter ON but AXIsProcessTrusted() is false,
    /// and flipping the dead switch does nothing. Clearing our TCC entry first is
    /// harmless on a fresh install and the only thing that works after an update,
    /// so granting ALWAYS resets before prompting.
    private func resetAndPromptAccessibility() {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.drew.prompter"]
            do {
                try process.run()
                process.waitUntilExit()
                Log.write("tccutil reset Accessibility exited \(process.terminationStatus)")
            } catch {
                Log.write("tccutil reset failed: \(error)")
            }
            DispatchQueue.main.async {
                let options = ["AXTrustedCheckOptionPrompt" as CFString as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    // MARK: Steps 4 & 5 — Hotkeys

    private var dictationKeyStep: some View {
        hotkeyChoiceStep(
            emoji: "🎤",
            question: "What key do you want to press to start talking?",
            blurb: "This one types your exact words — what you said, as-is, just cleaned up.",
            recommended: .rightOption,
            selection: $store.config.dictationHotkey,
            conflictWith: nil,
            target: .dictation
        )
    }

    private var promptKeyStep: some View {
        hotkeyChoiceStep(
            emoji: "✨",
            question: "What key do you want to press to do an AI prompt?",
            blurb: "This one doesn't just type what you said — it uses it to write a well-made prompt for an AI.",
            recommended: .rightCommand,
            selection: $store.config.promptHotkey,
            conflictWith: store.config.dictationHotkey,
            target: .prompt
        )
    }

    private func hotkeyChoiceStep(
        emoji: String,
        question: String,
        blurb: String,
        recommended: HotkeyKey,
        selection: Binding<String>,
        conflictWith: String?,
        target: HotkeyCaptureTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(emoji, question, blurb)

            Text("Choose a quick option below, or click Custom and press the shortcut you want. Then hit Continue.")
                .font(.callout)

            VStack(spacing: 8) {
                ForEach(HotkeyKey.allCases) { key in
                    keyRow(key,
                           recommended: key == recommended,
                           selected: selection.wrappedValue == key.rawValue) {
                        selection.wrappedValue = key.rawValue
                    }
                }
                customKeyRow(
                    selected: HotkeyKey(rawValue: selection.wrappedValue) == nil,
                    currentValue: selection.wrappedValue,
                    fallback: recommended
                ) {
                    hotkeyCaptureTarget = target
                }
            }

            if let conflictWith, HotkeyShortcut.matches(selection.wrappedValue, conflictWith) {
                Text("⚠️ That key is already doing dictation — pick a different one so both can work.")
                    .font(.callout).foregroundStyle(.orange)
            } else if selection.wrappedValue == HotkeyKey.fn.rawValue {
                Text("Using fn: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the system doesn't race Prompter.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func keyRow(_ key: HotkeyKey, recommended: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(key.display).font(.headline)
            if recommended {
                Text("Recommended")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.secondary.opacity(selected ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
    }

    private func customKeyRow(
        selected: Bool,
        currentValue: String,
        fallback: HotkeyKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text("Custom").font(.headline)
            if selected {
                Text(HotkeyShortcut.display(for: currentValue, fallback: fallback))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.secondary.opacity(selected ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
    }

    /// On the key-picker steps, pressing the physical key selects it. The live
    /// hotkey monitor must not treat that press as "start dictating", so those
    /// steps also raise DictationController.hotkeySelectionActive.
    private func updateKeyCapture(for step: Int) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        let selecting = step == 3 || step == 4
        DictationController.shared.hotkeySelectionActive = selecting
        guard selecting else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let key = HotkeyKey.allCases.first(where: { $0.keyCode == event.keyCode }),
                  event.modifierFlags.contains(key.flag) else { return event }
            if step == 3 {
                ConfigStore.shared.config.dictationHotkey = key.rawValue
            } else {
                ConfigStore.shared.config.promptHotkey = key.rawValue
            }
            return event
        }
    }

    // MARK: Step 6 — AI engine

    private var aiEngine: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("🧠", "Connect the AI",
                   "OpenRouter is optional. Apple handles speech locally by default; an OpenRouter key adds fast cleanup, styling, and Prompt Mode.")

            VStack(alignment: .leading, spacing: 10) {
                SecureField("OpenRouter API key (sk-or-…)", text: $store.config.openRouterKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        .font(.callout)
                    Spacer()
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing || store.config.openRouterKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !testResult.isEmpty {
                        Text(testResult).font(.callout)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    }
                }
            }

            Text("Default model: Gemini Flash Lite — fast and inexpensive. Optional Whisper transcription can be enabled later in Settings → AI models.")
                .font(.callout).foregroundStyle(.secondary)

            Text("No key? That's fine — skip this. Speech stays on your Mac with Apple's transcriber; cleanup can use your Claude Code subscription (claude CLI) if installed, or fall back to Dictionary corrections.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 7 — Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("🎉", "Try it right here",
                   "Click into the box below, then hold \(dictationKeyName) and say something like “Hey, just checking in — um, can we move the call to Tuesday... actually Wednesday?” Release and watch it come out clean.")

            TextEditor(text: $practiceText)
                .font(.body)
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.35)))

            VStack(alignment: .leading, spacing: 8) {
                bullet("hand.tap.fill", "Also try a single TAP of \(dictationKeyName) — hands-free mode. Tap again to finish.")
                bullet("wand.and.stars", "And hold \(promptKeyName) while describing something you want an AI to do.")
            }

            Text("That's it. Prompter lives in your menu bar (the waveform icon) — Dictionary, Style, Snippets, Insights, and Settings are all there.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var dictationKeyName: String {
        HotkeyShortcut.display(for: store.config.dictationHotkey, fallback: .rightOption, shortened: true)
    }
    private var promptKeyName: String {
        HotkeyShortcut.display(for: store.config.promptHotkey, fallback: .rightCommand, shortened: true)
    }

    private func header(_ emoji: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emoji).font(.system(size: 34))
            Text(title).font(.title.bold())
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(Color.accentColor)
            Text(text).font(.callout)
        }
    }

    private func statusRow(granted: Bool, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            Text(label).font(.headline)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runTest() {
        testing = true
        testResult = ""
        Task {
            do {
                let reply = try await LLMClient.shared.complete(
                    system: "Reply with exactly: OK",
                    user: "Say OK.",
                    model: ConfigStore.shared.config.cleanupModel,
                    timeout: 45
                )
                await MainActor.run {
                    testResult = reply.text.contains("OK") ? "✓ Connected" : "✓ Replied"
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
