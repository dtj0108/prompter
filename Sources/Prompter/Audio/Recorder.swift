import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private(set) var startTime: Date?
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

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.onBuffer?(buffer, when)
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
        startTime = nil
        return duration
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
