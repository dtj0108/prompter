import AppKit
import AVFoundation
import SwiftUI

/// Steps of the sign-in + onboarding flow. AppDelegate, DictationController,
/// and Ambitious sign-out all reopen the assistant directly on specific steps —
/// reference them by case, never by raw index.
enum OnboardingStep: Int, CaseIterable {
    // Ambitious-designed intro ("Ambitious Prompts Onboarding" design file).
    case welcome
    case justTalk
    case shapePrompt
    case stats
    /// The gate: there is no way past this screen without a signed-in identity.
    case signIn
    // Functional setup, in the same visual language.
    case microphone
    case accessibility
    case dictationKey
    case promptKey
    case aiEngine
    case tryIt

    static let introSteps: [OnboardingStep] = [.welcome, .justTalk, .shapePrompt, .stats, .signIn]
    static let setupSteps: [OnboardingStep] = [.microphone, .accessibility, .dictationKey, .promptKey, .aiEngine, .tryIt]

    var isIntro: Bool { rawValue <= OnboardingStep.signIn.rawValue }
}
/// Sign-in and setup assistant in the Ambitious onboarding design: a 680×640
/// chromeless card, five intro/sign-in screens, then the macOS permission and
/// hotkey setup restyled to match. Screens slide between steps and stagger
/// their content in; the intro demos use the real product UI (the HUD pill,
/// the Prompt Mode transformation) plus a why-voice-wins stats screen.
struct OnboardingView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var auth = AmbitiousAuthManager.shared
    @State private var step: OnboardingStep

    /// True for offscreen `--render-*` CLI snapshots: suppresses the permission
    /// prompts, tccutil reset, event monitors, and animations that live steps
    /// trigger, so renders capture the settled state.
    private let renderOnly: Bool

    init(startStep: OnboardingStep = .welcome, renderOnly: Bool = false) {
        _step = State(initialValue: startStep)
        self.renderOnly = renderOnly
    }

    @State private var micGranted = Recorder.micAuthorized()
    @State private var micRequesting = false
    @State private var axGranted = AXIsProcessTrusted()
    @State private var axRequesting = false
    @State private var testResult = ""
    @State private var testing = false
    @State private var practiceText = ""

    @State private var keyMonitor: Any?
    @State private var hotkeyCaptureTarget: HotkeyCaptureTarget?

    /// Direction of the last step change, so screens slide the way you're going.
    @State private var slideForward = true

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            bottomControls
        }
        .padding(.top, 16)
        .padding(.horizontal, 48)
        .padding(.bottom, 32)
        .frame(width: 680, height: 640)
        .background(AmbitiousDesign.background)
        .ignoresSafeArea()
        .onReceive(timer) { _ in
            micGranted = Recorder.micAuthorized()
            axGranted = AXIsProcessTrusted()
        }
        .onAppear { updateKeyCapture(for: step) }
        .onChange(of: step) { _, newStep in updateKeyCapture(for: newStep) }
        .onDisappear { updateKeyCapture(for: nil) }
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

    // MARK: Chrome

    /// Trailing link row. The window's traffic lights overlay the top-left, so
    /// this row only ever places content on the right. "Return to Prompter"
    /// requires a signed-in identity: without one there is no way out of this
    /// flow into the app — signing in with Ambitious IS the price of entry.
    private var topBar: some View {
        HStack {
            Spacer()
            if store.config.onboardingDone && auth.isSignedIn {
                SkipLink(label: "Return to Prompter") { returnToPrompter() }
            } else if step.rawValue < OnboardingStep.signIn.rawValue {
                SkipLink(label: "Skip") { goTo(.signIn) }
            }
        }
        .frame(minHeight: 32)
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {
            dots

            ZStack {
                switch step {
                case .signIn:
                    signInControls
                        .transition(.opacity)
                case .tryIt:
                    Button("Finish") { finish() }
                        .buttonStyle(AmbitiousPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .transition(.opacity)
                default:
                    Button("Next") { advance() }
                        .buttonStyle(AmbitiousPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(.top, 16)
    }

    /// Page dots for the current phase: the five designed intro screens, or the
    /// six setup steps. The active dot stretches into a brand-colored pill.
    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(step.isIntro ? OnboardingStep.introSteps : OnboardingStep.setupSteps, id: \.rawValue) { target in
                Capsule()
                    .fill(target == step ? AmbitiousDesign.brandPrimary : AmbitiousDesign.dotInactive)
                    .frame(width: target == step ? 24 : 8, height: 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .clickCursor()
                    .onTapGesture { goTo(target) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
    }

    private func advance() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) { goTo(next) }
    }

    /// All step navigation funnels through here so the slide direction and
    /// animation stay consistent (and CLI renders stay instant).
    private func goTo(_ target: OnboardingStep) {
        guard target != step else { return }
        slideForward = target.rawValue > step.rawValue
        if renderOnly {
            step = target
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { step = target }
        }
    }

    private func finish() {
        store.config.onboardingDone = true
        returnToPrompter()
    }

    private func returnToPrompter() {
        WindowRouter.shared.closeOnboarding()
        WindowRouter.shared.openMain()
    }

    // MARK: Screens

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcome
        case .justTalk: justTalk
        case .shapePrompt: shapePrompt
        case .stats: statsScreen
        case .signIn: signInScreen
        case .microphone: microphone
        case .accessibility: accessibility
        case .dictationKey: dictationKeyStep
        case .promptKey: promptKeyStep
        case .aiEngine: aiEngine
        case .tryIt: tryIt
        }
    }

    private var welcome: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 28) {
                AmbitiousWordmark(text: "ambitious prompts", size: 36, barWidth: 52, spacing: 8)
                    .popIn(shown)
                screenText("Welcome to Ambitious Prompts",
                           "Speak your ideas. Leave with prompts that deliver.")
                    .riseIn(shown, delay: 0.18)
            }
        }
    }

    private var justTalk: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 34) {
                OnboardingHUDDemo(animated: !renderOnly)
                    .popIn(shown)
                screenText("Just talk",
                           "Hold \(dictationKeyName) and describe what you need — or pick your own talking key in setup. Messy thoughts welcome.",
                           maxWidth: 340)
                    .riseIn(shown, delay: 0.18)
            }
        }
    }

    private var shapePrompt: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 24) {
                PromptTransformDemo(animated: !renderOnly)
                    .riseIn(shown)
                Text("We shape it into a prompt")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AmbitiousDesign.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .riseIn(shown, delay: 0.15)
            }
        }
    }

    private var statsScreen: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 24) {
                screenText("Why voice wins",
                           "This is what our team has found.",
                           maxWidth: 380)
                    .riseIn(shown)

                VStack(alignment: .leading, spacing: 14) {
                    statRow("waveform", "2.5× faster",
                            "You speak about 2.5× faster than you can type — ideas land while they're hot.",
                            shown: shown, delay: 0.12)
                    statRow("wand.and.stars", "2× better output",
                            "Talking gives the AI a richer, better-shaped prompt — so the code that comes back is dramatically better.",
                            shown: shown, delay: 0.2)
                    statRow("target", "More one-shots",
                            "Right prompts land on the first try, so you skip the back-and-forth.",
                            shown: shown, delay: 0.28)
                    statRow("dollarsign.circle", "Half the tokens",
                            "One-shots cut the retry loops — our token usage roughly halved, so you spend less and burn less of your account limits.",
                            shown: shown, delay: 0.36)
                }
                .frame(width: 440)
            }
        }
    }

    private func statRow(_ symbol: String, _ stat: String, _ caption: String, shown: Bool, delay: Double) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AmbitiousIconCircle(symbol: symbol, diameter: 40, symbolSize: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AmbitiousDesign.text)
                Text(caption)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(AmbitiousDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .riseIn(shown, delay: delay)
    }

    // MARK: Sign in

    private var signInScreen: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 28) {
                AmbitiousWordmark(text: "ambitious", size: 32, barWidth: 44, spacing: 6)
                    .popIn(shown)

                VStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("🎁").font(.system(size: 14))
                        Text("Free, courtesy of Ambitious Social")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AmbitiousDesign.brandPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(AmbitiousDesign.brandPrimary.opacity(0.1))
                            .overlay(Capsule().strokeBorder(AmbitiousDesign.brandPrimary.opacity(0.35), lineWidth: 1))
                    )
                    .popIn(shown, delay: 0.12)

                    VStack(spacing: 10) {
                        Text("Just sign in with your Ambitious account to get started.")
                            .font(.system(size: 16, weight: .medium))
                            .lineSpacing(5)
                            .foregroundStyle(AmbitiousDesign.text)
                            .frame(maxWidth: 320)
                        Text("You'll be asked to add your OpenRouter key. Free options cover up to 1,000 prompts a day — or go paid for top-tier performance, billed at API rates. We've been using it heavily and get charged about $2–$5 a month.")
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(AmbitiousDesign.textSecondary)
                            .frame(maxWidth: 400)
                    }
                    .multilineTextAlignment(.center)
                    .riseIn(shown, delay: 0.2)
                }
                .fixedSize(horizontal: false, vertical: true)

                Group {
                    if let identity = auth.identity {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(AmbitiousDesign.success)
                            Text(identity.email.map { "Signed in as \($0)" } ?? "Signed in with Ambitious")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AmbitiousDesign.text)
                        }
                    } else if let message = auth.errorMessage {
                        notice(message, color: AmbitiousDesign.error)
                    }
                }
                .riseIn(shown, delay: 0.25)
            }
        }
    }

    @ViewBuilder
    private var signInControls: some View {
        if auth.isSignedIn {
            VStack(spacing: 12) {
                Button("Continue") { advance() }
                    .buttonStyle(AmbitiousPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Text("Your sign-in is stored securely in your Mac's Keychain, and Prompter keeps working even when you're offline.")
                    .font(.system(size: 12))
                    .foregroundStyle(AmbitiousDesign.textTertiary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 12) {
                Button {
                    auth.signIn()
                } label: {
                    if auth.activity == .signingIn {
                        Text("Signing in…")
                    } else {
                        // Two lines: the second is the real logo lockup —
                        // heavy-italic "ambitious" over its short centered bar.
                        VStack(spacing: 5) {
                            Text("Sign in with")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            AmbitiousWordmark(text: "ambitious", size: 20, barWidth: 28, barHeight: 3, spacing: 4, color: .white)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .buttonStyle(AmbitiousBlackButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(auth.activity == .signingIn)

                Button("Create an Ambitious account") {
                    NSWorkspace.shared.open(URL(string: "https://www.ambitious.social")!)
                }
                .buttonStyle(AmbitiousSecondaryButtonStyle())

                Text("By continuing you agree to the [Terms](https://www.ambitious.social/terms) and [Privacy Policy](https://www.ambitious.social/privacy).")
                    .font(.system(size: 12))
                    .foregroundStyle(AmbitiousDesign.textTertiary)
                    .tint(AmbitiousDesign.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Microphone

    private var microphone: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 24) {
                AmbitiousIconCircle(symbol: "mic", diameter: 72, symbolSize: 28, glow: true, pulsing: !renderOnly)
                    .popIn(shown)
                screenText("Allow the microphone",
                           "So Prompter can hear you. Audio never leaves your Mac.",
                           maxWidth: 440)
                    .riseIn(shown, delay: 0.12)

                VStack(spacing: 14) {
                    statusRow(granted: micGranted,
                              label: micGranted ? "Microphone access granted" : "Microphone access needed")
                    if !micGranted {
                        Button(micRequesting ? "Requesting…" : "Allow Microphone") { requestMic() }
                            .buttonStyle(AmbitiousPrimaryButtonStyle(compact: true))
                            .disabled(micRequesting)
                        Text("Click “Allow” in the macOS dialog.")
                            .font(.system(size: 12))
                            .foregroundStyle(AmbitiousDesign.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        settingsLink("Open System Settings → Microphone", pane: "Privacy_Microphone")
                    }
                }
                .riseIn(shown, delay: 0.22)
            }
        }
        .onAppear { if !renderOnly && !micGranted { requestMic() } }
    }

    private func requestMic() {
        guard !micRequesting else { return }
        micRequesting = true
        Task {
            _ = await Recorder.requestMicAccess()
            micGranted = Recorder.micAuthorized()
            micRequesting = false
        }
    }

    // MARK: Accessibility

    private var accessibility: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 24) {
                AmbitiousIconCircle(symbol: "keyboard", diameter: 72, symbolSize: 28)
                    .popIn(shown)
                screenText("Allow Accessibility",
                           "Lets Prompter catch your hotkey in any app and type for you.",
                           maxWidth: 440)
                    .riseIn(shown, delay: 0.12)

                VStack(spacing: 14) {
                    statusRow(granted: axGranted,
                              label: axGranted ? "Accessibility granted" : "Accessibility needed")
                    if !axGranted {
                        Button(axRequesting ? "Opening System Settings…" : "Grant Accessibility") { requestAccessibility() }
                            .buttonStyle(AmbitiousPrimaryButtonStyle(compact: true))
                            .disabled(axRequesting)
                        Text("Turn ON the switch next to Prompter. This screen updates by itself.")
                            .font(.system(size: 12))
                            .foregroundStyle(AmbitiousDesign.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        settingsLink("Open System Settings → Accessibility", pane: "Privacy_Accessibility")
                    }
                }
                .riseIn(shown, delay: 0.22)
            }
        }
        .onAppear { if !renderOnly && !axGranted { requestAccessibility() } }
    }

    private func requestAccessibility() {
        guard !axRequesting else { return }
        axRequesting = true
        resetAndPromptAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { axRequesting = false }
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

    // MARK: Hotkeys

    private var dictationKeyStep: some View {
        hotkeyChoiceStep(
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
            question: "What key do you want to press to do an AI prompt?",
            blurb: "This one doesn't just type what you said — it uses it to write a well-made prompt for an AI.",
            recommended: .rightCommand,
            selection: $store.config.promptHotkey,
            conflictWith: store.config.dictationHotkey,
            target: .prompt
        )
    }

    private func hotkeyChoiceStep(
        question: String,
        blurb: String,
        recommended: HotkeyKey,
        selection: Binding<String>,
        conflictWith: String?,
        target: HotkeyCaptureTarget
    ) -> some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 20) {
                screenText(question, blurb, maxWidth: 440, titleSize: 24, subSize: 15)
                    .riseIn(shown)

                VStack(spacing: 8) {
                    ForEach(visibleKeys(for: selection.wrappedValue)) { key in
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
                .frame(width: 360)
                .riseIn(shown, delay: 0.12)

                KeyboardStrip(highlighted: HotkeyKey(rawValue: selection.wrappedValue))
                    .riseIn(shown, delay: 0.2)

                Group {
                    if let conflictWith, HotkeyShortcut.matches(selection.wrappedValue, conflictWith) {
                        notice("That shortcut is already doing dictation — pick a different one so both can work.",
                               color: AmbitiousDesign.warning, maxWidth: 400)
                    } else if selection.wrappedValue == HotkeyKey.fn.rawValue {
                        notice("Using fn: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the system doesn't race Prompter.",
                               color: AmbitiousDesign.textTertiary, maxWidth: 400)
                    }
                }
                .riseIn(shown, delay: 0.26)
            }
        }
    }

    /// v2 shows three preset rows (Right ⌥ / Right ⌘ / fn) plus Custom; the
    /// legacy Right ⇧ preset only appears while it's the current selection.
    private func visibleKeys(for selection: String) -> [HotkeyKey] {
        var keys: [HotkeyKey] = [.rightOption, .rightCommand]
        if HotkeyKey(rawValue: selection) == .rightShift { keys.append(.rightShift) }
        keys.append(.fn)
        return keys
    }

    private func keyRow(_ key: HotkeyKey, recommended: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        selectableRow(selected: selected, action: action) {
            Text(key == .fn ? "fn — Globe key" : key.display)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.text)
            if recommended {
                Text("Recommended")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AmbitiousDesign.brandPrimary.opacity(0.12), in: Capsule())
                    .foregroundStyle(AmbitiousDesign.brandPrimary)
            }
            Spacer()
        }
    }

    private func customKeyRow(
        selected: Bool,
        currentValue: String,
        fallback: HotkeyKey,
        action: @escaping () -> Void
    ) -> some View {
        selectableRow(selected: selected, action: action) {
            Text("Custom")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.text)
            if selected {
                Text(HotkeyShortcut.display(for: currentValue, fallback: fallback))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AmbitiousDesign.brandPrimary)
            }
            Spacer()
            Image(systemName: "keyboard")
                .foregroundStyle(AmbitiousDesign.textTertiary)
        }
    }

    private func selectableRow(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(selected ? AmbitiousDesign.brandPrimary : AmbitiousDesign.textTertiary, lineWidth: 2)
                Circle()
                    .fill(selected ? AmbitiousDesign.brandPrimary : Color.clear)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 16, height: 16)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? AmbitiousDesign.brandPrimary.opacity(0.08) : AmbitiousDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? AmbitiousDesign.brandPrimary.opacity(0.6) : AmbitiousDesign.border,
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .clickCursor()
        .onTapGesture(perform: action)
    }

    /// On the key-picker steps, pressing the physical key selects it. The live
    /// hotkey monitor must not treat that press as "start dictating", so those
    /// steps also raise DictationController.hotkeySelectionActive.
    private func updateKeyCapture(for step: OnboardingStep?) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        guard !renderOnly else { return }
        let selecting = step == .dictationKey || step == .promptKey
        DictationController.shared.hotkeySelectionActive = selecting
        guard selecting, let step else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let key = HotkeyKey.allCases.first(where: { $0.keyCode == event.keyCode }),
                  event.modifierFlags.contains(key.flag) else { return event }
            if step == .dictationKey {
                ConfigStore.shared.config.dictationHotkey = key.rawValue
            } else {
                ConfigStore.shared.config.promptHotkey = key.rawValue
            }
            return event
        }
    }

    // MARK: AI engine

    private var aiEngine: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 24) {
                AmbitiousIconCircle(symbol: "sparkles", diameter: 72, symbolSize: 28)
                    .popIn(shown)
                screenText("Connect the AI",
                           "OpenRouter is optional. Apple handles speech locally by default; an OpenRouter key adds fast cleanup, styling, and Prompt Mode.",
                           maxWidth: 440)
                    .riseIn(shown, delay: 0.12)

                VStack(spacing: 10) {
                    SecureField("OpenRouter API key (sk-or-…)", text: $store.config.openRouterKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AmbitiousDesign.background))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AmbitiousDesign.borderStrong, lineWidth: 1))
                    HStack(spacing: 10) {
                        Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .font(.system(size: 13))
                            .tint(AmbitiousDesign.brandPrimary)
                            .clickCursor()
                        Spacer()
                        if !testResult.isEmpty {
                            Text(testResult)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(testResult.hasPrefix("✓") ? AmbitiousDesign.success : AmbitiousDesign.error)
                        }
                        Button(testing ? "Testing…" : "Test") { runTest() }
                            .buttonStyle(AmbitiousPrimaryButtonStyle(compact: true))
                            .disabled(testing || store.config.openRouterKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(width: 360)
                .riseIn(shown, delay: 0.22)

                Text("No key? That's fine — skip this. Speech stays on your Mac with Apple's transcriber; cleanup can use your Claude Code subscription (claude CLI) if installed, or fall back to Dictionary corrections.")
                    .font(.system(size: 12))
                    .foregroundStyle(AmbitiousDesign.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .riseIn(shown, delay: 0.3)
            }
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        Entrance(enabled: !renderOnly) { shown in
            VStack(spacing: 20) {
                AmbitiousIconCircle(symbol: "party.popper.fill", diameter: 72, symbolSize: 28)
                    .popIn(shown)
                screenText("Try it right here",
                           "Click into the box below, then hold \(dictationKeyName) and say something like “Hey, just checking in — um, can we move the call to Tuesday... actually Wednesday?” Release and watch it come out clean.",
                           maxWidth: 460, titleSize: 26, subSize: 14)
                    .riseIn(shown, delay: 0.12)

                TextEditor(text: $practiceText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(width: 420, height: 96)
                    .background(RoundedRectangle(cornerRadius: 12).fill(AmbitiousDesign.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AmbitiousDesign.border, lineWidth: 1))
                    .riseIn(shown, delay: 0.2)

                VStack(alignment: .leading, spacing: 8) {
                    bullet("hand.tap.fill", "Also try a single TAP of \(dictationKeyName) — hands-free mode. Tap again to finish.")
                    bullet("wand.and.stars", "And hold \(promptKeyName) while describing something you want an AI to do.")
                }
                .frame(width: 440)
                .riseIn(shown, delay: 0.28)
            }
        }
    }

    // MARK: Helpers

    private var dictationKeyName: String {
        HotkeyShortcut.display(for: store.config.dictationHotkey, fallback: .rightOption, shortened: true)
    }
    private var promptKeyName: String {
        HotkeyShortcut.display(for: store.config.promptHotkey, fallback: .rightCommand, shortened: true)
    }

    /// The design's centered text block: bold title over secondary body.
    private func screenText(
        _ title: String,
        _ subtitle: String,
        maxWidth: CGFloat = 300,
        titleSize: CGFloat = 28,
        subSize: CGFloat = 16
    ) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(AmbitiousDesign.text)
            Text(subtitle)
                .font(.system(size: subSize))
                .lineSpacing(5)
                .foregroundStyle(AmbitiousDesign.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: maxWidth)
    }

    private func notice(_ text: String, color: Color, maxWidth: CGFloat = 320) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: maxWidth)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(AmbitiousDesign.brandPrimary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AmbitiousDesign.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(granted: Bool, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(granted ? AmbitiousDesign.success : AmbitiousDesign.warning)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.text)
        }
    }

    private func settingsLink(_ label: String, pane: String) -> some View {
        Button(label) { openPrivacyPane(pane) }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AmbitiousDesign.brandPrimary)
            .clickCursor()
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

/// The design's top-right text link ("Skip", "Return to Prompter").
private struct SkipLink: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovered ? AmbitiousDesign.textSecondary : AmbitiousDesign.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .clickCursor()
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Entrance animation

/// Owns the entrance state for one screen: flips `shown` on appear so elements
/// can stagger in with `riseIn`/`popIn`. Disabled (always shown) for CLI renders.
private struct Entrance<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var shown = false

    var body: some View {
        content(shown || !enabled)
            .onAppear {
                guard enabled else { return }
                shown = true
            }
    }
}

private struct RiseIn: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay), value: shown)
    }
}

private struct PopIn: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.82)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.72).delay(delay), value: shown)
    }
}

private extension View {
    func riseIn(_ shown: Bool, delay: Double = 0) -> some View {
        modifier(RiseIn(shown: shown, delay: delay))
    }

    func popIn(_ shown: Bool, delay: Double = 0) -> some View {
        modifier(PopIn(shown: shown, delay: delay))
    }
}

/// The v2 keyboard visual under the hotkey pickers: a strip of modifier
/// keycaps with the currently selected preset lit up in brand blue.
private struct KeyboardStrip: View {
    let highlighted: HotkeyKey?

    var body: some View {
        HStack(spacing: 5) {
            keycap("fn", "🌐", width: 46, key: .fn)
            keycap("⌃", "control", width: 52)
            keycap("⌥", "option", width: 52)
            keycap("⌘", "command", width: 62)
            spacebar
            keycap("⌘", "command", width: 62, key: .rightCommand)
            keycap("⌥", "option", width: 52, key: .rightOption)
        }
        .frame(width: 420)
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }

    private var spacebar: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(AmbitiousDesign.card)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AmbitiousDesign.border, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .shadow(color: .black.opacity(0.05), radius: 0, y: 1)
    }

    private func keycap(_ glyph: String, _ name: String, width: CGFloat, key: HotkeyKey? = nil) -> some View {
        let on = key != nil && key == highlighted
        return VStack(spacing: 1) {
            Text(glyph).font(.system(size: 13, weight: .semibold))
            Text(name).font(.system(size: 8)).tracking(0.3)
        }
        .foregroundStyle(on ? AmbitiousDesign.brandPrimary : AmbitiousDesign.textSecondary)
        .frame(width: width, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(on ? AmbitiousDesign.brandPrimary.opacity(0.12) : AmbitiousDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(on ? AmbitiousDesign.brandPrimary : AmbitiousDesign.border, lineWidth: on ? 1.5 : 1)
        )
        .shadow(color: on ? AmbitiousDesign.brandPrimary.opacity(0.35) : .black.opacity(0.05),
                radius: on ? 9 : 0, y: on ? 0 : 1)
    }
}

// MARK: - Intro demos

/// Faithful replica of the real dictation HUD in its listening state (HUD.swift):
/// same capsule, red status dot, and 26-bar scrolling waveform — driven by a
/// speech-like level generator so the intro shows exactly what a take looks like.
private struct OnboardingHUDDemo: View {
    let animated: Bool
    @State private var levels: [CGFloat]
    @State private var clock: Double = 0
    private let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    init(animated: Bool) {
        self.animated = animated
        _levels = State(initialValue: (0..<HUDModel.barCount).map { i in
            let phase = Double(i) * 0.48
            return CGFloat(max(0.06, abs(sin(phase)) * (0.35 + 0.65 * abs(sin(phase * 0.31 + 0.9)))))
        })
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
                .frame(width: 8, height: 8)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.5 + 0.5 * levels[i]))
                        .frame(width: 3, height: 3 + levels[i] * 22)
                }
            }
            .frame(width: 150, height: 26)
            .animation(.linear(duration: 0.06), value: levels)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        )
        .scaleEffect(1.4)
        .frame(width: 300, height: 72)
        .onReceive(timer) { _ in tick() }
    }

    private func tick() {
        guard animated else { return }
        clock += 0.06
        // Bursts of speech separated by near-silence, like a real take.
        let envelope = max(0, sin(clock * 1.8)) * (0.55 + 0.45 * sin(clock * 0.7 + 1.4))
        let level = envelope < 0.12
            ? CGFloat.random(in: 0...0.05)
            : CGFloat(envelope) * CGFloat.random(in: 0.45...1.0)
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }
}

/// The screen-3 demo: a spoken take types itself out, then Prompt Mode's
/// structured result writes in line by line — looping like a product demo.
/// Layout space is fully reserved up front so the screen never jumps.
private struct PromptTransformDemo: View {
    let animated: Bool

    private static let quote = "“uhh the login button's broken on mobile, probably a z-index thing — fix it and add a test…”"
    private static let lines: [(text: String, weight: Font.Weight, brand: Bool)] = [
        ("# Fix broken login button on mobile", .bold, true),
        ("## Context", .semibold, true),
        ("Tap does nothing on iOS Safari", .regular, false),
        ("## Task", .semibold, true),
        ("- Find and fix the z-index bug", .regular, false),
        ("- Add a regression test", .regular, false),
        ("## Constraints", .semibold, true),
        ("- Don't touch the desktop layout", .regular, false),
    ]

    @State private var typedCount: Int
    @State private var showArrow: Bool
    @State private var shownLines: Int
    @State private var player: Task<Void, Never>?

    init(animated: Bool) {
        self.animated = animated
        _typedCount = State(initialValue: animated ? 0 : Self.quote.count)
        _showArrow = State(initialValue: !animated)
        _shownLines = State(initialValue: animated ? 0 : Self.lines.count)
    }

    var body: some View {
        VStack(spacing: 10) {
            quoteCard
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.brandPrimary)
                .opacity(showArrow ? 1 : 0)
            promptCard
                .opacity(shownLines > 0 ? 1 : 0.35)
        }
        .frame(width: 380)
        .onAppear(perform: startPlayer)
        .onDisappear {
            player?.cancel()
            player = nil
        }
    }

    private var isTyping: Bool { animated && typedCount > 0 && typedCount < Self.quote.count }

    private var quoteCard: some View {
        ZStack(alignment: .topLeading) {
            quoteText(Self.quote).opacity(0) // reserve the finished size
            quoteText(String(Self.quote.prefix(typedCount)) + (isTyping ? "▍" : ""))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(AmbitiousDesign.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AmbitiousDesign.border, lineWidth: 1))
    }

    private func quoteText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 15).italic())
            .lineSpacing(4)
            .foregroundStyle(AmbitiousDesign.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROMPT")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(AmbitiousDesign.brandPrimary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.lines.indices, id: \.self) { i in
                    Text(Self.lines[i].text)
                        .font(.system(size: 13, weight: Self.lines[i].weight, design: .monospaced))
                        .foregroundStyle(Self.lines[i].brand ? AmbitiousDesign.brandPrimary : AmbitiousDesign.text)
                        .opacity(i < shownLines ? 1 : 0)
                        .offset(y: i < shownLines ? 0 : 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(AmbitiousDesign.brandPrimary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AmbitiousDesign.brandPrimary.opacity(0.35), lineWidth: 1))
    }

    private func startPlayer() {
        guard animated, player == nil else { return }
        player = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    typedCount = 0
                    showArrow = false
                    shownLines = 0
                }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
                for count in 1...Self.quote.count {
                    if Task.isCancelled { return }
                    typedCount = count
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.3)) { showArrow = true }
                try? await Task.sleep(for: .milliseconds(400))
                for line in 1...Self.lines.count {
                    if Task.isCancelled { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shownLines = line }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                try? await Task.sleep(for: .milliseconds(3200))
            }
        }
    }
}
