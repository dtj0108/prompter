import Foundation

struct CloudTranscriptionResult {
    var text: String
    var costUSD: Double
}

enum CloudTranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case apiFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenRouter API key to use cloud transcription."
        case .apiFailed(let message):
            return message
        case .emptyResponse:
            return "The transcription model returned no text."
        }
    }
}

/// One-shot speech-to-text through OpenRouter's dedicated transcription API.
/// The caller owns the temporary audio file and removes it after this returns.
enum OpenRouterTranscriber {
    static let defaultModel = "openai/whisper-large-v3-turbo"

    private static let retryableNetworkCodes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .timedOut,
    ]

    /// Whisper can emit this exact phrase for silent or malformed audio. Only
    /// use this signal alongside a different, non-empty local transcript so a
    /// user who genuinely says "thank you" is not rejected.
    static func isLikelySilenceHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return normalized == "thank you"
    }

    static func transcribeFile(
        _ url: URL,
        model: String,
        language: String = "en",
        timeout: TimeInterval = 12
    ) async throws -> CloudTranscriptionResult {
        let key = ConfigStore.shared.config.openRouterKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }

        let audio = try Data(contentsOf: url)
        let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": requestedModel.isEmpty ? defaultModel : requestedModel,
            "input_audio": [
                "data": audio.base64EncodedString(),
                "format": "wav",
            ],
            "language": language,
            "temperature": 0,
        ]

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/drewbaskin/prompter", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Ambitious Prompts", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataWithTransientRetries(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.apiFailed("OpenRouter returned no HTTP response.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let apiMessage = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw CloudTranscriptionError.apiFailed(
                "OpenRouter transcription \(http.statusCode): \(String(apiMessage.prefix(300)))"
            )
        }

        let text = (json?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CloudTranscriptionError.emptyResponse }
        let cost = ((json?["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue ?? 0
        return CloudTranscriptionResult(text: text, costUSD: cost)
    }

    /// A dictation should not be lost because the first TLS handshake or socket
    /// briefly failed. Retry only transient transport failures, using a fresh
    /// ephemeral session after the shared-session attempt so a bad connection
    /// cannot be reused.
    private static func dataWithTransientRetries(
        for request: URLRequest,
        maxAttempts: Int = 2
    ) async throws -> (Data, URLResponse) {
        precondition(maxAttempts > 0)

        for attempt in 0..<maxAttempts {
            let session = attempt == 0
                ? URLSession.shared
                : URLSession(configuration: .ephemeral)
            do {
                let result = try await session.data(for: request)
                if attempt > 0 { session.finishTasksAndInvalidate() }
                return result
            } catch {
                if attempt > 0 { session.invalidateAndCancel() }
                let code = (error as? URLError)?.code
                guard attempt + 1 < maxAttempts,
                      let code,
                      retryableNetworkCodes.contains(code) else {
                    throw error
                }

                let delayMs = 250 * (attempt + 1)
                Log.write(
                    "OpenRouter transcription transport failed (\(code.rawValue)); " +
                    "retrying attempt \(attempt + 2)/\(maxAttempts)"
                )
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }

        throw URLError(.unknown)
    }
}
