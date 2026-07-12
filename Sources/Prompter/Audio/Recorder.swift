import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private(set) var startTime: Date?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var didLogRecordingError = false
    /// Real microphones always carry noise-floor dither; a sustained run of
    /// exact digital zeros means a DSP unit or a revoked permission is muting
    /// the input, not a quiet room.
    private var nonSilentSampleSeen = false
    private var silentFrames = 0
    private var silenceReported = false
    /// Fired once, on the audio tap thread, after ~1 s of pure digital silence.
    var onDigitalSilence: (() -> Void)?
    var heardOnlySilence: Bool { !nonSilentSampleSeen }
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Live mic level 0…1 for the waveform HUD, several times per buffer.
    /// Called on the audio tap thread.
    var onLevel: ((Float) -> Void)?
    /// Fired when the audio engine dies mid-recording (mic unplugged, AirPods
    /// switch, sleep). Called on an arbitrary thread.
    var onInterrupted: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Apple's voice-processing DSP: suppresses background noise and voices
    /// other than the dominant, near-field speaker. MUST be applied before
    /// `inputFormat` is read for a session — toggling it changes the input
    /// node's format, and the transcriber is primed with that format.
    func applyVoiceIsolation(_ enabled: Bool) {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != enabled else { return }
        do {
            try input.setVoiceProcessingEnabled(enabled)
            Log.write("voice isolation \(enabled ? "enabled" : "disabled")")
        } catch {
            // Never block dictation on DSP setup — plain capture still works.
            Log.write("voice isolation toggle failed: \(error)")
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let config = ConfigStore.shared.config
        let cloudTranscriptionEnabled = config.useOpenRouterTranscription
            && !config.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if cloudTranscriptionEnabled {
            prepareCloudRecording(inputFormat: format)
        } else {
            discardRecording()
        }
        nonSilentSampleSeen = false
        silentFrames = 0
        silenceReported = false
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.onBuffer?(buffer, when)
            self.writeCloudRecording(buffer)
            self.emitLevels(buffer)
            self.trackSilence(buffer)
        }
        engine.prepare()
        try engine.start()
        startTime = Date()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.startTime != nil else { return }
            self.onInterrupted?()
        }
    }

    /// Stops capture and returns the recorded duration in seconds.
    @discardableResult
    func stop() -> Double {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Releasing AVAudioFile flushes and finalizes the WAV header before the
        // processing task reads it.
        recordingFile = nil
        startTime = nil
        return duration
    }

    /// Transfers ownership of the completed temporary WAV to the caller.
    func takeRecordingURL() -> URL? {
        defer { recordingURL = nil }
        return recordingURL
    }

    func discardRecording() {
        recordingFile = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    /// Capture the exact native mic buffers as a WAV alongside Apple's live
    /// analyzer. Avoid resampling on the real-time audio thread: on some input
    /// formats AVAudioConverter produced a correctly timed but silent file.
    private func prepareCloudRecording(inputFormat: AVAudioFormat) {
        discardRecording()
        didLogRecordingError = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompter-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            recordingFile = file
            recordingURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.write("cloud recording setup failed; local STT remains available: \(error)")
        }
    }

    /// Called only by AVAudioEngine's serial tap callback.
    private func writeCloudRecording(_ buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile else { return }
        do {
            if buffer.frameLength > 0 { try file.write(from: buffer) }
        } catch {
            if !didLogRecordingError {
                didLogRecordingError = true
                Log.write("cloud recording write failed; local STT remains available: \(error)")
            }
        }
    }

    /// Called only by AVAudioEngine's serial tap callback.
    private func trackSilence(_ buffer: AVAudioPCMBuffer) {
        guard !nonSilentSampleSeen, let channel = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) where channel[i] != 0 {
            nonSilentSampleSeen = true
            return
        }
        silentFrames += Int(buffer.frameLength)
        if !silenceReported, Double(silentFrames) >= buffer.format.sampleRate {
            silenceReported = true
            onDigitalSilence?()
        }
    }

    /// RMS level per sub-chunk of the buffer (~3 samples per ~85 ms buffer keeps
    /// the waveform lively), mapped from dB to 0…1.
    private func emitLevels(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let chunks = 3
        let chunkLen = max(1, frames / chunks)
        var start = 0
        while start < frames {
            let end = min(frames, start + chunkLen)
            var sum: Float = 0
            for i in start..<end {
                let s = channel[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(end - start))
            let db = 20 * log10(max(rms, 1e-7))
            let normalized = max(0, min(1, (db + 50) / 42)) // ≈ -50 dB floor, -8 dB ceiling
            onLevel(normalized)
            start = end
        }
    }

    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
