import AppKit
import AVFoundation

/// Hotkey → GPT Live Transcribe → optional cleanup → output → history.
final class DictationController {
    static let shared = DictationController()
    private let hotkeys = HotkeyMonitor()
    private let recorder = Recorder()

    private struct Session {
        var mode: DictationMode
        var context: FrontContext
        var startedAt: Date
        var engine: OpenAIRealtimeTranscriber
        var liveText: LiveTextSession?
    }

    private var session: Session?
    private var busy = false
    var hasInFlightDictation: Bool { session != nil || busy }
    var isPaused = false
    var hotkeySelectionActive = false {
        didSet {
            if hotkeySelectionActive != oldValue { hotkeys.resetState() }
        }
    }
    private var maxDurationTimer: DispatchWorkItem?
    private var sessionGen = 0

    func start() {
        hotkeys.onBegin = { [weak self] mode, handsFree in
            DispatchQueue.main.async { self?.beginSession(mode: mode, handsFree: handsFree) }
        }
        hotkeys.onCommit = { [weak self] in
            DispatchQueue.main.async { self?.commitSession(resetHotkeyState: false) }
        }
        hotkeys.onAbort = { [weak self] in
            DispatchQueue.main.async { self?.abortSession() }
        }
        hotkeys.start()
        recorder.onLevel = { level in HUD.shared.level(level) }
        recorder.onInterrupted = { [weak self] in
            DispatchQueue.main.async { self?.commitSession(wasInterrupted: true) }
        }
        recorder.onDigitalSilence = { [weak self] in
            DispatchQueue.main.async { self?.recoverFromSilentCapture() }
        }
        if !AXIsProcessTrusted() {
            let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.hotkeys.start()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

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
        guard !OpenAICredentials.currentAPIKey().isEmpty else {
            HUD.shared.flash(.failure("Add your OpenAI key in Settings → API Keys"), for: 4)
            WindowRouter.shared.openSettings()
            return
        }
        guard Recorder.micAuthorized() else {
            Task {
                if !(await Recorder.requestMicAccess()) {
                    HUD.shared.flash(.failure("Grant microphone access in Settings"))
                }
            }
            return
        }
        let config = ConfigStore.shared.config
        recorder.applyVoiceIsolation(config.voiceIsolationEnabled)
        let context = ContextDetector.capture()
        let wantsLiveTyping = mode == .dictate && config.liveTypingEnabled
        let liveText = wantsLiveTyping ? LiveTextSession.capture(shortcuts: config.shortcuts(for: .dictate)) : nil
        let engine = OpenAIRealtimeTranscriber()
        engine.lowLatency = wantsLiveTyping
        LLMClient.shared.prewarmConnection()
        session = Session(mode: mode, context: context, startedAt: Date(), engine: engine, liveText: liveText)
        sessionGen += 1
        let gen = sessionGen
        engine.onTranscript = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen else { return }
                self.session?.liveText?.receive(text)
            }
        }
        engine.onFailure = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen else { return }
                self.commitSession(wasInterrupted: true)
            }
        }
        playSound("Pop")
        Task { @MainActor in
            do {
                try await engine.begin(inputFormat: recorder.inputFormat)
                // Only touch this session's engine after an async startup; a new
                // hotkey session may have started while this one was cancelled.
                guard gen == sessionGen, session != nil else {
                    engine.cancel()
                    liveText?.cancel()
                    return
                }
                recorder.onBuffer = { [weak engine] buffer, _ in engine?.feed(buffer) }
                try recorder.start()
                HUD.shared.show(.listening(mode, handsFree: handsFree))
                let work = DispatchWorkItem { [weak self] in self?.commitSession() }
                maxDurationTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(config.maxRecordingSec), execute: work)
            } catch {
                engine.cancel()
                liveText?.cancel()
                guard gen == sessionGen else { return }
                session = nil
                recorder.stop()
                recorder.onBuffer = nil
                let reason = (error as? OpenAIRealtimeTranscriptionError)?.popupMessage
                HUD.shared.flash(.failure(reason ?? "Couldn't start GPT Live Transcribe — check your key and connection"), for: 5)
                Log.write("dictation begin failed: \(error)")
                hotkeys.resetState()
                notifyAuthIfIdle()
            }
        }
    }

    private func commitSession(wasInterrupted: Bool = false, resetHotkeyState: Bool = true) {
        guard let current = session, !busy else { return }
        session = nil
        sessionGen += 1
        busy = true
        maxDurationTimer?.cancel()
        if resetHotkeyState { hotkeys.resetState() }
        let audioSec = recorder.stop()
        let heardOnlySilence = recorder.heardOnlySilence
        recorder.onBuffer = nil
        playSound("Tink")
        if audioSec < 0.35 && !wasInterrupted && current.engine.availableText.isEmpty {
            current.engine.cancel()
            current.liveText?.cancel()
            busy = false
            HUD.shared.hide()
            notifyAuthIfIdle()
            return
        }
        HUD.shared.show(.processing(current.mode))
        Task { @MainActor in
            defer {
                busy = false
                notifyAuthIfIdle()
            }
            let sttStart = Date()
            let transcription: OpenAIRealtimeTranscriptionResult
            do {
                transcription = try await current.engine.finishResult()
            } catch {
                current.engine.cancel()
                current.liveText?.cancel()
                Log.write("GPT Live Transcribe failed: \(error)")
                // OpenAI's own reason (bad key, no credit…) beats every generic hint.
                let reason = (error as? OpenAIRealtimeTranscriptionError)?.popupMessage
                let message = reason ?? (heardOnlySilence
                    ? "No mic signal — recheck Microphone permission"
                    : "GPT Live Transcribe failed — check your OpenAI key and connection")
                HUD.shared.flash(.failure(message), for: reason == nil ? 4 : 5)
                return
            }
            let sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
            let rawTranscript = transcription.text
            // Show the complete raw text while optional cleanup runs. Subsequent
            // edits/focus changes suspend the session, including during cleanup.
            current.liveText?.receive(rawTranscript)
            let output: (String, Int, Bool, Double)
            if transcription.isPartial {
                output = (rawTranscript, 0, false, 0)
            } else {
                output = await transform(transcript: rawTranscript, session: current)
            }
            let (transformedText, llmMs, usedLLM, cleanupCostUSD) = output
            let finalText = transformedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? rawTranscript : transformedText
            let pasteResult: PasteResult
            if let liveText = current.liveText {
                if liveText.finish(finalText) {
                    pasteResult = .pasted
                } else {
                    _ = Paster.insert(finalText, allowPaste: false)
                    pasteResult = .clipboardOnly(reason: "Live typing stopped — finished text copied, ⌘V to paste")
                }
            } else {
                // Normal mode and unsupported fields retain the current paste-at-cursor behavior.
                let front = NSWorkspace.shared.frontmostApplication
                let sameApp = current.context.bundleId.isEmpty
                    || (front?.bundleIdentifier == current.context.bundleId
                        && front?.processIdentifier == current.context.pid)
                let canPasteHere = sameApp || ContextDetector.focusedTextTarget() != .rejectsText
                let result = Paster.insert(finalText, targetPID: front?.processIdentifier, allowPaste: canPasteHere)
                pasteResult = canPasteHere ? result : .clipboardOnly(reason: "No text cursor — ⌘V to paste")
            }
            let words = finalText.split(whereSeparator: { $0.isWhitespace }).count
            InsightsStore.shared.append(InsightEvent(
                ts: current.startedAt, app: current.context.appName,
                bundleId: current.context.bundleId, context: current.context.style.id,
                mode: current.mode.rawValue, audioSec: audioSec, words: words,
                sttMs: sttMs, llmMs: llmMs,
                engine: "openai/\(OpenAIRealtimeTranscriber.defaultModel)" + (transcription.isPartial ? "-partial" : ""),
                costUSD: transcription.costUSD + cleanupCostUSD, rawText: rawTranscript, finalText: finalText
            ))
            switch pasteResult {
            case .pasted:
                if transcription.isPartial {
                    HUD.shared.flash(.failure("Connection interrupted — recovered \(words) words"), for: 4)
                } else {
                    HUD.shared.flash(.success(usedLLM ? "\(words) words" : "\(words) words (raw — AI skipped)"))
                }
            case .clipboardOnly(let reason):
                let label = transcription.isPartial ? "Connection interrupted — received words copied" : reason
                HUD.shared.flash(.failure(label), for: 4)
            }
        }
    }

    private func recoverFromSilentCapture() {
        guard session != nil, !busy, ConfigStore.shared.config.voiceIsolationEnabled else { return }
        recorder.stop()
        recorder.applyVoiceIsolation(false)
        ConfigStore.shared.config.voiceIsolationEnabled = false
        do {
            try recorder.start()
        } catch {
            Log.write("restart after silent capture failed: \(error)")
            commitSession(wasInterrupted: true)
        }
    }

    private func abortSession() {
        guard let current = session else { return }
        session = nil
        sessionGen += 1
        maxDurationTimer?.cancel()
        recorder.stop()
        recorder.onBuffer = nil
        current.engine.cancel()
        current.liveText?.cancel()
        HUD.shared.hide()
        notifyAuthIfIdle()
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
