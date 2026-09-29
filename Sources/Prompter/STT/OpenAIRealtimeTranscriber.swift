import AVFoundation
import Foundation

struct OpenAIRealtimeTranscriptionResult {
    var text: String
    var costUSD: Double
    var isPartial: Bool = false
}

enum OpenAIRealtimeTranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case invalidAudioFormat
    case apiFailed(String)
    /// OpenAI refused the request and said why (bad key, no credit, no model access…).
    case openAIRejected(code: String?, message: String?)
    case unreachable
    case emptyResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to use GPT Live Transcribe."
        case .invalidAudioFormat:
            return "The microphone audio could not be converted for GPT Live Transcribe."
        case .apiFailed(let message):
            return message
        case .openAIRejected(let code, let message):
            return OpenAIRealtimeTranscriptionError.explain(code: code, message: message)
        case .unreachable:
            return "Can't reach OpenAI — check your internet connection"
        case .emptyResponse:
            return "GPT Live Transcribe returned no text."
        case .timeout:
            return "GPT Live Transcribe took too long to finalize."
        }
    }

    /// The specific reason to show the user, or nil when only a generic hint fits.
    var popupMessage: String? {
        switch self {
        case .openAIRejected, .unreachable, .missingAPIKey: return errorDescription
        default: return nil
        }
    }

    /// Turns OpenAI's error into one short line (it must fit the 480pt HUD) that
    /// says what to fix. Unknown errors keep OpenAI's own words, minus any key.
    static func explain(code: String?, message: String?) -> String {
        let text = (message ?? "").lowercased()
        switch code {
        case "invalid_api_key":
            return "OpenAI rejected this key — paste it again in Settings → API Keys"
        case "insufficient_quota":
            return "OpenAI account is out of credit — add billing at platform.openai.com"
        case "model_not_found":
            return "This OpenAI project can't use \(OpenAIRealtimeTranscriber.defaultModel) — check its limits"
        case "rate_limit_exceeded":
            return "OpenAI rate limit reached — wait a moment and try again"
        default:
            break
        }
        if text.contains("insufficient permissions") || text.contains("missing scopes") {
            return "This OpenAI key is restricted — create one with All permissions"
        }
        if text.contains("does not have access to model") || text.contains("does not exist") {
            return "This OpenAI project can't use \(OpenAIRealtimeTranscriber.defaultModel) — check its limits"
        }
        if text.contains("incorrect api key") {
            return "OpenAI rejected this key — paste it again in Settings → API Keys"
        }
        let cleaned = (message ?? "")
            .replacingOccurrences(of: #"sk-[A-Za-z0-9_*.-]+"#, with: "sk-…", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "OpenAI couldn't start GPT Live Transcribe" }
        let limit = 64
        return "OpenAI: " + (cleaned.count > limit ? cleaned.prefix(limit - 1) + "…" : cleaned)
    }
}

enum OpenAICredentials {
    static func currentAPIKey() -> String {
        let stored = ConfigStore.shared.config.openAIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }

        let environment = ProcessInfo.processInfo.environment
        let processKey = (environment["OPENAI_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !processKey.isEmpty { return processKey }

        if let path = environment["PROMPTER_OPENAI_ENV_FILE"],
           let key = apiKey(fromEnvironmentFileAt: URL(fileURLWithPath: path)) {
            return key
        }
        return ""
    }

    static func apiKey(fromEnvironmentFileAt url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return apiKey(fromEnvironmentFileContents: contents)
    }

    static func apiKey(fromEnvironmentFileContents contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard name == "OPENAI_API_KEY" else { continue }

            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" || first == "'"),
               last == first {
                value.removeFirst()
                value.removeLast()
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

private final class SerialWebSocketSender: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: URLSessionWebSocketTask
    private let onError: @Sendable (Error) -> Void
    private var tail: Task<Void, Never>?
    private var cancelled = false

    init(socket: URLSessionWebSocketTask, onError: @escaping @Sendable (Error) -> Void) {
        self.socket = socket
        self.onError = onError
    }

    func enqueue(_ text: String) {
        lock.lock()
        let previous = tail
        let socket = self.socket
        let onError = self.onError
        let next = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, !self.lock.withLock({ self.cancelled }) else { return }
            do {
                try await socket.send(.string(text))
            } catch {
                onError(error)
            }
        }
        tail = next
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = tail
        lock.unlock()
        task?.cancel()
    }
}

/// A single manually committed audio turn, transcribed only by GPT Live Transcribe.
/// Deltas are retained even when live insertion is off so failures can recover words.
final class OpenAIRealtimeTranscriber: @unchecked Sendable {
    /// Called on the receive task. UI consumers must hop to the main queue.
    var onTranscript: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var lowLatency = false

    static let defaultModel = "gpt-live-transcribe"
    static let pricePerMinuteUSD = 0.017

    static func estimatedCostUSD(audioSeconds: Double) -> Double {
        max(0, audioSeconds) / 60 * pricePerMinuteUSD
    }

    private struct ServerEvent: Decodable {
        struct APIError: Decodable {
            var code: String?
            var message: String?
        }

        struct Usage: Decodable {
            var type: String?
            var seconds: Double?
        }

        var type: String
        var event_id: String?
        var item_id: String?
        var delta: String?
        var transcript: String?
        var error: APIError?
        var usage: Usage?
    }

    private let stateLock = NSLock()
    private let converter = BufferConverter()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var socket: URLSessionWebSocketTask?
    private var sender: SerialWebSocketSender?
    private var receiveTask: Task<Void, Never>?
    private var transcript = ""
    private var activeItemID: String?
    private var seenEvents = Set<String>()
    private var usageSeconds: Double?
    private var streamedAudioSeconds: Double = 0
    private var completionReceived = false
    private var terminalError: Error?
    private var isCancelled = false
    private(set) var lastCostUSD: Double = 0

    var availableText: String { snapshot().text }

    func begin(inputFormat: AVAudioFormat) async throws {
        let key = OpenAICredentials.currentAPIKey()
        guard !key.isEmpty else { throw OpenAIRealtimeTranscriptionError.missingAPIKey }
        resetState()

        let socket = URLSession.shared.webSocketTask(with: Self.realtimeRequest(key: key))
        self.socket = socket
        self.sender = SerialWebSocketSender(socket: socket) { [weak self] error in
            self?.recordTerminalError(error)
        }
        socket.resume()
        startReceiving(from: socket)

        try enqueue(Self.sessionUpdateEvent(lowLatency: lowLatency, keywords: Self.contextKeywords()))
    }

    private static func realtimeRequest(key: String) -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func sessionUpdateEvent(lowLatency: Bool, keywords: [String]) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": defaultModel,
            "languages": ["en"],
            "delay": lowLatency ? "low" : "medium",
        ]
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
    }

    /// Proves a key can open a GPT Live Transcribe session: connects exactly as
    /// dictation does and sends the same session setup, but no audio, so it costs
    /// nothing. Returns nil on success, or the reason to show the user.
    static func checkKey(_ rawKey: String) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return OpenAIRealtimeTranscriptionError.missingAPIKey.errorDescription }
        let socket = URLSession.shared.webSocketTask(with: realtimeRequest(key: key))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        do {
            let setup = try JSONSerialization.data(withJSONObject: sessionUpdateEvent(lowLatency: false, keywords: []))
            try await socket.send(.string(String(decoding: setup, as: UTF8.self)))
        } catch {
            return describe(error)
        }
        return await withTaskGroup(of: String??.self) { group in
            group.addTask {
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await socket.receive() } catch { return .some(describe(error)) }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard let event = try? JSONDecoder().decode(ServerEvent.self, from: data) else { continue }
                    if event.type == "error" {
                        return .some(OpenAIRealtimeTranscriptionError.explain(
                            code: event.error?.code, message: event.error?.message
                        ))
                    }
                    // OpenAI confirms the transcription setup (model included) was accepted.
                    if event.type.hasSuffix(".updated") { return .some(nil) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return .some("OpenAI didn't answer — check your internet connection")
            }
            let first = await group.next() ?? .some("OpenAI didn't answer — check your internet connection")
            group.cancelAll()
            socket.cancel(with: .normalClosure, reason: nil)
            return first ?? nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, Self.isOffline(urlError) {
            return OpenAIRealtimeTranscriptionError.unreachable.errorDescription!
        }
        return "Couldn't connect to OpenAI: \(error.localizedDescription)"
    }

    private static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let state = snapshot()
        guard !state.cancelled, state.error == nil else { return }
        do {
            let converted = try converter.convert(buffer, to: outputFormat)
            guard converted.frameLength > 0 else { return }
            let audioBuffer = converted.audioBufferList.pointee.mBuffers
            guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                throw OpenAIRealtimeTranscriptionError.invalidAudioFormat
            }
            let data = Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
            let event: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ]
            try enqueue(event)
            stateLock.lock()
            streamedAudioSeconds += Double(converted.frameLength) / outputFormat.sampleRate
            stateLock.unlock()
        } catch {
            recordTerminalError(error)
        }
    }

    func finish() async throws -> String {
        let result = try await finishResult()
        return result.text
    }

    func finishResult() async throws -> OpenAIRealtimeTranscriptionResult {
        defer { closeConnection() }
        // Sending is serialized; the commit follows every queued audio buffer.
        // Do not await the send queue here: a broken socket must not evade the deadline.
        do {
            try throwIfFailed()
            try enqueue(["type": "input_audio_buffer.commit"])
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let state = snapshot()
                if state.cancelled { throw CancellationError() }
                // A completed result wins over a subsequent normal socket closure.
                if state.completed {
                    let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw OpenAIRealtimeTranscriptionError.emptyResponse }
                    return makeResult(state: state, isPartial: state.error != nil)
                }
                if let error = state.error { throw normalize(error) }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw OpenAIRealtimeTranscriptionError.timeout
        } catch {
            let state = snapshot()
            guard !state.cancelled, !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error
            }
            Log.write("GPT Live Transcribe interrupted; preserving received text")
            return makeResult(state: state, isPartial: true)
        }
    }

    private func makeResult(state: StateSnapshot, isPartial: Bool) -> OpenAIRealtimeTranscriptionResult {
        let seconds = state.usageSeconds ?? state.streamedSeconds
        let cost = Self.estimatedCostUSD(audioSeconds: seconds)
        stateLock.withLock { lastCostUSD = cost }
        return OpenAIRealtimeTranscriptionResult(
            text: state.text.trimmingCharacters(in: .whitespacesAndNewlines),
            costUSD: cost,
            isPartial: isPartial
        )
    }

    func cancel() {
        stateLock.lock()
        isCancelled = true
        stateLock.unlock()
        closeConnection()
    }

    static func transcribeFile(_ url: URL, paced: Bool = false) async throws -> OpenAIRealtimeTranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        let engine = OpenAIRealtimeTranscriber()
        engine.lowLatency = paced
        let progress = StreamingDiagnosticProgress()
        if paced {
            engine.onTranscript = { _ in progress.receivedUpdate() }
        }
        do {
            try await engine.begin(inputFormat: file.processingFormat)
            let capacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw OpenAIRealtimeTranscriptionError.invalidAudioFormat
            }
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(
                    min(AVAudioFramePosition(capacity), file.length - file.framePosition)
                )
                try file.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { break }
                engine.feed(buffer)
                if paced {
                    let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
            let updates = progress.beginCommit()
            let result = try await engine.finishResult()
            if paced {
                print("Streaming updates before commit: \(updates)")
                guard updates > 0, !result.isPartial else {
                    throw OpenAIRealtimeTranscriptionError.apiFailed("Streaming diagnostic did not receive a complete live transcript.")
                }
            }
            return result
        } catch {
            engine.cancel()
            throw error
        }
    }

    private static func contextKeywords() -> [String] {
        let keywords: [String] = DictionaryStore.shared.entries
            .map { $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                    && !$0.contains("<")
                    && !$0.contains(">")
                    && !$0.contains("\r")
                    && !$0.contains("\n")
            }
        return Array(keywords.prefix(100))
    }

    private func enqueue(_ event: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8), let sender else {
            throw OpenAIRealtimeTranscriptionError.apiFailed("OpenAI Realtime connection is not ready.")
        }
        sender.enqueue(text)
    }

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .data(let data):
                        self.handleServerEvent(data)
                    case .string(let text):
                        self.handleServerEvent(Data(text.utf8))
                    @unknown default:
                        break
                    }
                } catch {
                    if !self.snapshot().cancelled { self.recordTerminalError(error) }
                    return
                }
            }
        }
    }

    // Internal so event parsing, reconciliation and recovery are tested without a socket.
    func handleServerEvent(_ data: Data) {
        guard let event = try? JSONDecoder().decode(ServerEvent.self, from: data) else { return }
        if event.type == "error" || event.type == "conversation.item.input_audio_transcription.failed" {
            recordTerminalError(event.type == "error"
                ? OpenAIRealtimeTranscriptionError.openAIRejected(code: event.error?.code, message: event.error?.message)
                : OpenAIRealtimeTranscriptionError.apiFailed(
                    event.error?.message ?? "GPT Live Transcribe could not finish transcription."
                ))
            return
        }
        let isDelta = event.type == "conversation.item.input_audio_transcription.delta"
        let isFinal = event.type == "conversation.item.input_audio_transcription.completed"
        guard isDelta || isFinal, let itemID = event.item_id else { return }
        stateLock.lock()
        guard !isCancelled, !completionReceived,
              activeItemID == nil || activeItemID == itemID else {
            stateLock.unlock()
            return
        }
        if let id = event.event_id, !seenEvents.insert(id).inserted {
            stateLock.unlock()
            return
        }
        activeItemID = itemID
        if isDelta {
            transcript += event.delta ?? ""
        } else {
            if let final = event.transcript, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcript = final
            } else if !transcript.isEmpty {
                // Never erase useful deltas with an empty completion.
                terminalError = OpenAIRealtimeTranscriptionError.emptyResponse
            }
            usageSeconds = event.usage?.seconds
            completionReceived = true
        }
        let text = transcript
        stateLock.unlock()
        onTranscript?(text)
    }

    private func resetState() {
        closeConnection()
        stateLock.lock()
        transcript = ""
        activeItemID = nil
        seenEvents.removeAll()
        usageSeconds = nil
        streamedAudioSeconds = 0
        completionReceived = false
        terminalError = nil
        isCancelled = false
        lastCostUSD = 0
        stateLock.unlock()
    }

    private func recordTerminalError(_ error: Error) {
        stateLock.lock()
        let shouldNotify = terminalError == nil && !isCancelled && !completionReceived
        if shouldNotify { terminalError = error }
        stateLock.unlock()
        if shouldNotify { onFailure?() }
    }

    private func throwIfFailed() throws {
        if let error = snapshot().error { throw normalize(error) }
    }

    private func normalize(_ error: Error) -> Error {
        if error is OpenAIRealtimeTranscriptionError { return error }
        if let urlError = error as? URLError {
            if Self.isOffline(urlError) { return OpenAIRealtimeTranscriptionError.unreachable }
            return OpenAIRealtimeTranscriptionError.apiFailed(
                "OpenAI Realtime connection failed: \(urlError.localizedDescription)"
            )
        }
        return OpenAIRealtimeTranscriptionError.apiFailed(
            "OpenAI Realtime connection failed: \(error.localizedDescription)"
        )
    }

    private typealias StateSnapshot = (
        text: String,
        usageSeconds: Double?,
        streamedSeconds: Double,
        completed: Bool,
        error: Error?,
        cancelled: Bool
    )

    private func snapshot() -> StateSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            transcript,
            usageSeconds,
            streamedAudioSeconds,
            completionReceived,
            terminalError,
            isCancelled
        )
    }

    private func closeConnection() {
        sender?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        sender = nil
        receiveTask = nil
        socket = nil
    }
}

/// Tracks only event counts, never transcript text or credentials.
private final class StreamingDiagnosticProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var committing = false
    private var updates = 0
    func receivedUpdate() { lock.withLock { if !committing { updates += 1 } } }
    func beginCommit() -> Int { lock.withLock { committing = true; return updates } }
}
