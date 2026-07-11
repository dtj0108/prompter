import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private(set) var startTime: Date?
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
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
            self?.onBuffer?(buffer, when)
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

    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
