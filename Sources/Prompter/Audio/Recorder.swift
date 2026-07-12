import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private(set) var startTime: Date?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var recordingConverter: AVAudioConverter?
    private var recordingFormat: AVAudioFormat?
    private var didLogRecordingError = false
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
        prepareCloudRecording(inputFormat: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.onBuffer?(buffer, when)
            self.writeCloudRecording(buffer)
            self.emitLevels(buffer)
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
        recordingConverter = nil
        recordingFormat = nil
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
        recordingConverter = nil
        recordingFormat = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    /// Capture a compact 16 kHz mono PCM WAV alongside Apple's live analyzer.
    /// Five minutes is about 9.6 MB before base64 encoding.
    private func prepareCloudRecording(inputFormat: AVAudioFormat) {
        discardRecording()
        didLogRecordingError = false
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            Log.write("could not create cloud recording format; local STT remains available")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompter-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw NSError(domain: "Prompter.Recorder", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not create the audio converter",
                ])
            }
            converter.primeMethod = .none
            recordingFile = file
            recordingURL = url
            recordingConverter = converter
            recordingFormat = outputFormat
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.write("cloud recording setup failed; local STT remains available: \(error)")
        }
    }

    /// Called only by AVAudioEngine's serial tap callback.
    private func writeCloudRecording(_ buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile,
              let converter = recordingConverter,
              let outputFormat = recordingFormat else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let inputBuffer = buffer
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        do {
            guard status != .error else { throw conversionError ?? NSError(domain: "Prompter.Recorder", code: 2) }
            if output.frameLength > 0 { try file.write(from: output) }
        } catch {
            if !didLogRecordingError {
                didLogRecordingError = true
                Log.write("cloud recording write failed; local STT remains available: \(error)")
            }
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
