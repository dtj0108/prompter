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

    static func transcribeFile(
        _ url: URL,
        model: String,
        language: String = "en",
        timeout: TimeInterval = 75
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
        request.setValue("Prompter", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
}
