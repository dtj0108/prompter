import AppKit
import AVFoundation

/// Orchestrates one dictation session: hotkey → record → transcribe → LLM → paste → log.
final class DictationController {
    static let shared = DictationController()

    private let hotkeys = HotkeyMonitor()
    private let recorder = Recorder()
    private var engine: TranscriptionEngine = SpeechAnalyzerEngine()

    private struct Session {
        var mode: DictationMode
        var context: FrontContext
        var startedAt: Date
        var handsFree: Bool = false
    }

    private var session: Session?
    private var busy = false
    var hasInFlightDictation: Bool { session != nil || busy }
    var isPaused = false
    /// True while onboarding's key-picker steps are on screen: pressing a
    /// modifier key there is choosing a hotkey, not starting a dictation.
    var hotkeySelectionActive = false {
        didSet {
            if hotkeySelectionActive != oldValue { hotkeys.resetState() }
        }
    }
    private var maxDurationTimer: DispatchWorkItem?
    /// Bumped on every session start/stop; async startup steps abort if it moved.
    private var sessionGen = 0

    func start() {
        hotkeys.onBegin = { [weak self] mode, handsFree in
            DispatchQueue.main.async { self?.beginSession(mode: mode, handsFree: handsFree) }
        }
        hotkeys.onCommit = { [weak self] in
            DispatchQueue.main.async { self?.commitSession() }
        }
        hotkeys.onAbort = { [weak self] in
            DispatchQueue.main.async { self?.abortSession() }
        }
        hotkeys.start()

        recorder.onLevel = { level in
            HUD.shared.level(level)
        }

        // Mic disappeared mid-recording (device switch, sleep): salvage what we heard.
        recorder.onInterrupted = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.session != nil else { return }
                Log.write("audio engine configuration changed mid-recording — committing early")
                self.commitSession()
            }
        }

        // The mic is producing exact digital zeros: something upstream is
        // muting it — recover mid-session instead of ending in "Didn't catch that".
        recorder.onDigitalSilence = { [weak self] in
            DispatchQueue.main.async { self?.recoverFromSilentCapture() }
        }

        // Global NSEvent monitors registered before Accessibility was granted never
        // start delivering events — re-register once the grant appears.
        if !AXIsProcessTrusted() {
            let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    Log.write("accessibility granted — re-registering hotkey monitors")
                    self?.hotkeys.start()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        // Warm up the speech model check in the background.
        Task {
            do {
                try await engine.prepare()
                Log.write("speech engine ready")
            } catch {
                Log.write("speech engine prepare failed: \(error)")
            }
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(mode: DictationMode, handsFree: Bool = false) {
        guard !hotkeySelectionActive else { return }
        guard AmbitiousAuthManager.shared.isSignedIn else {
            HUD.shared.flash(.failure("Sign in with Ambitious to use Ambitious Prompts"), for: 3.5)
            WindowRouter.shared.openOnboarding(startStep: .signIn)
            return
        }
        guard !isPaused else {
            HUD.shared.flash(.failure("Ambitious Prompts is paused"))
            return
        }
        guard !busy else {
            HUD.shared.flash(.failure("Still finishing the last one…"))
            return
        }
        guard session == nil else { return }

        guard Recorder.micAuthorized() else {
            Task {
                let granted = await Recorder.requestMicAccess()
                if !granted {
                    HUD.shared.flash(.failure("Grant microphone access in Settings"))
                }
            }
            return
        }

        // Before engine.begin reads recorder.inputFormat — toggling voice
        // processing changes that format.
        recorder.applyVoiceIsolation(ConfigStore.shared.config.voiceIsolationEnabled)

        let context = ContextDetector.capture()
        // Overlap the TLS handshake with the user talking.
        LLMClient.shared.prewarmConnection()
        session = Session(mode: mode, context: context, startedAt: Date(), handsFree: handsFree)
        sessionGen += 1
        let gen = sessionGen
        playSound("Pop")

        Task { @MainActor in
            do {
                try await engine.begin(inputFormat: recorder.inputFormat)
                // The user may have released/cancelled while the engine was starting.
                guard gen == sessionGen, session != nil else {
                    engine.cancel()
                    return
                }
                recorder.onBuffer = { [weak self] buffer, _ in
                    self?.engine.feed(buffer)
                }
                try recorder.start()
                HUD.shared.show(.listening(mode, handsFree: handsFree))

                let maxSec = Double(ConfigStore.shared.config.maxRecordingSec)
                let work = DispatchWorkItem { [weak self] in self?.commitSession() }
                maxDurationTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + maxSec, execute: work)
            } catch {
                Log.write("begin failed: \(error)")
                if gen == sessionGen {
                    session = nil
                    recorder.stop()
                    recorder.discardRecording()
                    engine.cancel()
                    HUD.shared.flash(.failure("Couldn't start recording"))
                    notifyAuthIfIdle()
                }
            }
        }
    }

    private func commitSession() {
        guard let current = session, !busy else { return }
        session = nil
        sessionGen += 1
        busy = true
        maxDurationTimer?.cancel()

        let audioSec = recorder.stop()
        let heardOnlySilence = recorder.heardOnlySilence
        let recordingURL = recorder.takeRecordingURL()
        recorder.onBuffer = nil
        playSound("Tink")

        // Too-short accidental presses: throw away.
        if audioSec < 0.35 {
            if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            busy = false
            engine.cancel()
            HUD.shared.hide()
            notifyAuthIfIdle()
            return
        }

        HUD.shared.show(.processing(current.mode))

        Task {
            defer {
                if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            }
            let sttStart = Date()
            let transcription = await self.transcribe(recordingURL: recordingURL)
            let sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
            let transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcript.isEmpty else {
                await MainActor.run {
                    if heardOnlySilence {
                        HUD.shared.flash(.failure("No mic signal — recheck Microphone permission"), for: 4)
                    } else {
                        HUD.shared.flash(.failure("Didn't catch that"))
                    }
                    self.busy = false
                    self.notifyAuthIfIdle()
                }
                return
            }

            let rawTranscript = transcript
            let (finalText, llmMs, usedLLM, cleanupCostUSD) = await self.transform(transcript: rawTranscript, session: current)

            await MainActor.run {
                // Paste wherever the user's cursor is NOW: same app as when they
                // dictated, or a different app they clicked into while we were
                // polishing. Paste by default — even when accessibility can't
                // confirm a text cursor — and go clipboard-only ONLY when focus
                // is provably somewhere text can't go (desktop, a button, …).
                let front = NSWorkspace.shared.frontmostApplication
                let sameApp = current.context.bundleId.isEmpty
                    || (front?.bundleIdentifier == current.context.bundleId
                        && front?.processIdentifier == current.context.pid)
                let canPasteHere = sameApp || ContextDetector.focusedTextTarget() != .rejectsText
                let targetPID = front?.processIdentifier

                var pasteResult = Paster.insert(finalText, targetPID: targetPID, allowPaste: canPasteHere)
                if !canPasteHere {
                    pasteResult = .clipboardOnly(reason: "No text cursor — ⌘V to paste")
                }
                let words = finalText.split(whereSeparator: { $0.isWhitespace }).count

                InsightsStore.shared.append(InsightEvent(
                    ts: current.startedAt,
                    app: current.context.appName,
                    bundleId: current.context.bundleId,
                    context: current.context.style.id,
                    mode: current.mode.rawValue,
                    audioSec: audioSec,
                    words: words,
                    sttMs: sttMs,
                    llmMs: llmMs,
                    engine: transcription.engine,
                    costUSD: transcription.costUSD + cleanupCostUSD,
                    rawText: rawTranscript,
                    finalText: finalText
                ))

                switch pasteResult {
                case .pasted:
                    let label = usedLLM ? "\(words) words" : "\(words) words (raw — AI skipped)"
                    HUD.shared.flash(.success(label))
                case .clipboardOnly(let reason):
                    HUD.shared.flash(.failure(reason), for: 3.5)
                }
                self.busy = false
                self.notifyAuthIfIdle()
            }
        }
    }

    /// A real room never yields sustained exact zeros — the input is being muted
    /// upstream. Apple's voice-processing DSP (`setVoiceProcessingEnabled`) is the
    /// known offender on some Macs: drop it, restart capture within the running
    /// session, and remember the choice so later dictations start clean.
    private func recoverFromSilentCapture() {
        guard session != nil, !busy else { return }
        guard ConfigStore.shared.config.voiceIsolationEnabled else {
            Log.write("mic delivering pure silence with voice isolation off — microphone grant is likely broken")
            return
        }
        Log.write("mic delivering pure silence — disabling voice isolation and restarting capture")
        recorder.stop()
        recorder.applyVoiceIsolation(false)
        ConfigStore.shared.config.voiceIsolationEnabled = false
        do {
            try recorder.start()
        } catch {
            Log.write("restart after silent capture failed: \(error)")
            abortSession()
            HUD.shared.flash(.failure("Couldn't restart the microphone"))
        }
    }

    private func abortSession() {
        guard session != nil else { return }
        session = nil
        sessionGen += 1
        maxDurationTimer?.cancel()
        recorder.stop()
        recorder.discardRecording()
        recorder.onBuffer = nil
        engine.cancel()
        HUD.shared.hide()
        notifyAuthIfIdle()
    }

    // MARK: - Transform

    /// Apple's local analyzer is the fast default. Whisper Turbo is used only
    /// when the user explicitly enables cloud transcription; Apple continues
    /// in parallel as its fallback.
    private func transcribe(recordingURL: URL?) async -> (text: String, costUSD: Double, engine: String) {
        async let localTranscript = engine.finish()
        let config = ConfigStore.shared.config
        let useCloudTranscription = config.useOpenRouterTranscription
            && !config.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if useCloudTranscription, let recordingURL {
            do {
                let cloud = try await OpenRouterTranscriber.transcribeFile(
                    recordingURL,
                    model: config.openRouterTranscriptionModel
                )
                // Always let the parallel analyzer shut down cleanly before a
                // new recording can start. It also protects against Whisper's
                // known silent-audio "Thank you" hallucination.
                let local = ((try? await localTranscript) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if OpenRouterTranscriber.isLikelySilenceHallucination(cloud.text),
                   !local.isEmpty,
                   !OpenRouterTranscriber.isLikelySilenceHallucination(local) {
                    Log.write("OpenRouter returned a likely silence hallucination; using local transcript")
                    return (local, 0, "apple-speechanalyzer-fallback")
                }
                return (
                    cloud.text,
                    cloud.costUSD,
                    "openrouter/\(config.openRouterTranscriptionModel)"
                )
            } catch {
                Log.write("OpenRouter transcription failed; using local Apple transcript: \(error)")
            }
        }

        do {
            return (try await localTranscript, 0, "apple-speechanalyzer")
        } catch {
            Log.write("local STT finish failed: \(error)")
            return ("", 0, "apple-speechanalyzer")
        }
    }

    /// Returns (finalText, llmMs, usedLLM, costUSD). Never loses the transcript: falls
    /// back to dictionary-corrected raw text if the LLM is disabled or fails.
    private func transform(transcript: String, session: Session) async -> (String, Int, Bool, Double) {
        let config = ConfigStore.shared.config
        let dictionary = DictionaryStore.shared.entries.filter { !$0.phrase.isEmpty }

        let system: String
        let user: String
        let model: String
        let openRouterModel: String?
        let temperature: Double
        switch session.mode {
        case .dictate:
            // Whole utterance is a snippet trigger ("my email address") → expand
            // instantly, no AI round-trip.
            if let snippet = SnippetStore.shared.exactMatch(for: transcript) {
                return (snippet.expansion, 0, true, 0)
            }
            guard config.llmCleanupEnabled else {
                return (DictionaryStore.shared.applyRawCorrections(to: transcript), 0, false, 0)
            }
            system = Prompts.cleanupSystemPrompt(context: session.context, style: StyleStore.shared.style, dictionary: dictionary, snippets: SnippetStore.shared.snippets, separateThoughts: config.separateThoughts)
            user = Prompts.cleanupUserPrompt(transcript: transcript)
            model = config.cleanupModel
            openRouterModel = config.openRouterCleanupModel
            temperature = 0.2
        case .prompt:
            let level = PromptAssistLevel(rawValue: config.promptAssistLevel) ?? .medium
            system = Prompts.promptModeSystemPrompt(dictionary: dictionary, level: level)
            user = Prompts.promptModeUserPrompt(transcript: transcript, level: level)
            model = config.promptModel
            openRouterModel = nil // the main configured model
            // Prompt rewriting should be repeatable and instruction-faithful.
            temperature = 0
        }

        let llmStart = Date()
        do {
            let result = try await LLMClient.shared.complete(system: system, user: user, model: model, openRouterModel: openRouterModel, temperature: temperature)
            let ms = Int(Date().timeIntervalSince(llmStart) * 1000)
            let finalText = session.mode == .prompt
                ? Prompts.promptModeOutput(polishedPrompt: result.text, transcript: transcript)
                : result.text
            return (finalText, ms, true, result.costUSD)
        } catch {
            Log.write("llm transform failed (\(session.mode.rawValue)): \(error)")
            let ms = Int(Date().timeIntervalSince(llmStart) * 1000)
            return (DictionaryStore.shared.applyRawCorrections(to: transcript), ms, false, 0)
        }
    }

    private func playSound(_ name: String) {
        guard ConfigStore.shared.config.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private func notifyAuthIfIdle() {
        guard !hasInFlightDictation else { return }
        AmbitiousAuthManager.shared.dictationDidBecomeIdle()
    }
}
