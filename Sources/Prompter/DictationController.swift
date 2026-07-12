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
    }

    private var session: Session?
    private var busy = false
    var isPaused = false
    private var maxDurationTimer: DispatchWorkItem?
    /// Bumped on every session start/stop; async startup steps abort if it moved.
    private var sessionGen = 0

    func start() {
        hotkeys.onBegin = { [weak self] mode in
            DispatchQueue.main.async { self?.beginSession(mode: mode) }
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

    private func beginSession(mode: DictationMode) {
        guard !isPaused else {
            HUD.shared.flash(.failure("Prompter is paused"))
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

        let context = ContextDetector.capture()
        session = Session(mode: mode, context: context, startedAt: Date())
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
                HUD.shared.show(.listening(mode))

                let maxSec = Double(ConfigStore.shared.config.maxRecordingSec)
                let work = DispatchWorkItem { [weak self] in self?.commitSession() }
                maxDurationTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + maxSec, execute: work)
            } catch {
                Log.write("begin failed: \(error)")
                if gen == sessionGen {
                    session = nil
                    recorder.stop()
                    engine.cancel()
                    HUD.shared.flash(.failure("Couldn't start recording"))
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
        recorder.onBuffer = nil
        playSound("Tink")

        // Too-short accidental presses: throw away.
        if audioSec < 0.35 {
            busy = false
            engine.cancel()
            HUD.shared.hide()
            return
        }

        HUD.shared.show(.processing(current.mode))

        Task {
            let sttStart = Date()
            var transcript = ""
            do {
                transcript = try await engine.finish()
            } catch {
                Log.write("stt finish failed: \(error)")
            }
            let sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
            transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcript.isEmpty else {
                await MainActor.run {
                    HUD.shared.flash(.failure("Didn't catch that"))
                    self.busy = false
                }
                return
            }

            let (finalText, llmMs, usedLLM) = await self.transform(transcript: transcript, session: current)

            await MainActor.run {
                // Don't fire a synthetic ⌘V into a different app than the one dictated
                // into — the LLM step can take long enough for the user to switch away.
                let front = NSWorkspace.shared.frontmostApplication
                let sameApp = current.context.bundleId.isEmpty
                    || (front?.bundleIdentifier == current.context.bundleId
                        && front?.processIdentifier == current.context.pid)

                var pasteResult = Paster.insert(finalText, allowPaste: sameApp)
                if !sameApp {
                    pasteResult = .clipboardOnly(reason: "App changed — text is on your clipboard (⌘V)")
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
                    engine: "apple-speechanalyzer"
                ))

                switch pasteResult {
                case .pasted:
                    let label = usedLLM ? "\(words) words" : "\(words) words (raw — AI skipped)"
                    HUD.shared.flash(.success(label))
                case .clipboardOnly(let reason):
                    HUD.shared.flash(.failure(reason), for: 3.5)
                }
                self.busy = false
            }
        }
    }

    private func abortSession() {
        guard session != nil else { return }
        session = nil
        sessionGen += 1
        maxDurationTimer?.cancel()
        recorder.stop()
        recorder.onBuffer = nil
        engine.cancel()
        HUD.shared.hide()
    }

    // MARK: - Transform

    /// Returns (finalText, llmMs, usedLLM). Never loses the transcript: falls back to
    /// dictionary-corrected raw text if the LLM is disabled or fails.
    private func transform(transcript: String, session: Session) async -> (String, Int, Bool) {
        let config = ConfigStore.shared.config
        let dictionary = DictionaryStore.shared.entries.filter { !$0.phrase.isEmpty }

        let system: String
        let user: String
        let model: String
        switch session.mode {
        case .dictate:
            guard config.llmCleanupEnabled else {
                return (DictionaryStore.shared.applyRawCorrections(to: transcript), 0, false)
            }
            system = Prompts.cleanupSystemPrompt(context: session.context, style: StyleStore.shared.style, dictionary: dictionary)
            user = Prompts.cleanupUserPrompt(transcript: transcript)
            model = config.cleanupModel
        case .prompt:
            system = Prompts.promptModeSystemPrompt(dictionary: dictionary)
            user = Prompts.promptModeUserPrompt(transcript: transcript)
            model = config.promptModel
        }

        let llmStart = Date()
        do {
            let result = try await LLMClient.shared.complete(system: system, user: user, model: model)
            let ms = Int(Date().timeIntervalSince(llmStart) * 1000)
            return (result, ms, true)
        } catch {
            Log.write("llm transform failed (\(session.mode.rawValue)): \(error)")
            let ms = Int(Date().timeIntervalSince(llmStart) * 1000)
            return (DictionaryStore.shared.applyRawCorrections(to: transcript), ms, false)
        }
    }

    private func playSound(_ name: String) {
        guard ConfigStore.shared.config.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }
}
