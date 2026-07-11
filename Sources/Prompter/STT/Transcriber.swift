import Foundation
import Speech
import AVFoundation
import CoreMedia

enum TranscriptionError: Error, LocalizedError {
    case notAvailable
    case localeNotSupported
    case noCompatibleAudioFormat
    case timeout

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "On-device speech recognition is not available on this Mac."
        case .localeNotSupported: return "English (US) is not supported by the speech engine."
        case .noCompatibleAudioFormat: return "No compatible audio format for the speech engine."
        case .timeout: return "The speech engine took too long to finalize."
        }
    }
}

protocol TranscriptionEngine: AnyObject {
    func prepare() async throws
    func begin(inputFormat: AVAudioFormat) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

/// Converts mic buffers to the analyzer's required format.
/// AVAudioConverter is not Sendable; this box is only ever touched from the
/// audio tap's serial callback context.
final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case converterCreationFailed
        case bufferAllocationFailed
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }

        if converter == nil || converter!.inputFormat != buffer.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // .none avoids the converter swallowing leading samples for filter priming.
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.converterCreationFailed }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.bufferAllocationFailed
        }

        // The input block is called synchronously within convert(to:error:).
        var consumed = false
        let inputBuffer = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else { throw ConversionError.conversionFailed(conversionError) }
        return output
    }
}

/// On-device transcription via macOS 26's SpeechAnalyzer/SpeechTranscriber.
/// Fully local, no speech-recognition authorization needed — only the mic permission.
final class SpeechAnalyzerEngine: TranscriptionEngine {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    private let textLock = NSLock()
    private var finalizedText = ""

    private func resetText() {
        textLock.lock()
        finalizedText = ""
        textLock.unlock()
    }

    private func appendFinal(_ piece: String) {
        textLock.lock()
        finalizedText += piece
        textLock.unlock()
    }

    private func snapshotText() -> String {
        textLock.lock()
        defer { textLock.unlock() }
        return finalizedText
    }

    private static func resolveLocale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notAvailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
            throw TranscriptionError.localeNotSupported
        }
        return locale
    }

    /// Dictionary phrases used to bias recognition. Apple caps contextual strings
    /// at 100 phrases; short phrases (1-2 words) work best.
    private static func contextualPhrases() -> [String] {
        DictionaryStore.shared.entries
            .map { $0.phrase.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 4 }
            .prefix(100)
            .map { String($0) }
    }

    // MARK: - TranscriptionEngine

    /// Ensure the on-device model is installed (idempotent; instant after first run).
    func prepare() async throws {
        let locale = try await Self.resolveLocale()
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }

    func begin(inputFormat: AVAudioFormat) async throws {
        resetText()
        let locale = try await Self.resolveLocale()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let phrases = Self.contextualPhrases()
        if !phrases.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: phrases]
            try? await analyzer.setContext(context)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        analyzerFormat = format

        // Start consuming results BEFORE starting analysis (required ordering).
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    if result.isFinal {
                        self.appendFinal(String(result.text.characters))
                    }
                }
            } catch {
                Log.write("stt results stream ended with error: \(error)")
            }
        }

        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        try await analyzer.start(inputSequence: inputSequence)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat, let builder = inputBuilder else { return }
        guard let converted = try? converter.convert(buffer, to: format) else { return }
        builder.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        inputBuilder?.finish()
        inputBuilder = nil
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask

        do {
            try await withTimeout(seconds: 15) {
                // Pending volatile audio is re-emitted as final results, then the stream ends.
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                await resultsTask?.value
            }
        } catch {
            Log.write("stt finalize failed: \(error)")
            resultsTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }

        self.analyzer = nil
        self.transcriber = nil
        self.resultsTask = nil
        self.analyzerFormat = nil
        return snapshotText()
    }

    func cancel() {
        inputBuilder?.finish()
        inputBuilder = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer = analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        resetText()
    }

    // MARK: - One-shot file transcription (headless testing)

    static func transcribeFile(_ url: URL) async throws -> String {
        let locale = try await resolveLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let phrases = contextualPhrases()
        if !phrases.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: phrases]
            try? await analyzer.setContext(context)
        }

        let audioFile = try AVAudioFile(forReading: url)

        async let transcriptFuture: AttributedString = transcriber.results.reduce(into: AttributedString()) { acc, result in
            acc += result.text
        }

        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let transcript = try await transcriptFuture
        return String(transcript.characters)
    }
}

// MARK: - Timeout helper

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
