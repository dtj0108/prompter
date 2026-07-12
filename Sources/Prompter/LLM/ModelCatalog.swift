import Foundation

struct AIModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

enum TranscriptionModelCatalog {
    static let choices: [AIModelChoice] = [
        AIModelChoice(
            id: OpenRouterTranscriber.defaultModel,
            name: "Whisper Large V3 Turbo",
            detail: "Fast · $0.04/hour"
        ),
    ]

    static func choice(for id: String) -> AIModelChoice? {
        choices.first { $0.id == id }
    }
}

enum AIModelCatalog {
    static let choices: [AIModelChoice] = [
        AIModelChoice(id: "openrouter/free", name: "Free", detail: "OpenRouter free model router"),
        AIModelChoice(id: "openai/gpt-5.6-luna", name: "GPT 5.6", detail: "Luna — smallest GPT-5.6"),
        AIModelChoice(id: "x-ai/grok-4.5", name: "Grok 4.5", detail: "xAI"),
        AIModelChoice(id: "anthropic/claude-sonnet-5", name: "Sun 5", detail: "Claude Sonnet 5"),
        AIModelChoice(id: "google/gemini-3.1-flash-lite", name: "Gemini Flash", detail: "Gemini 3.1 Flash Lite"),
    ]

    static func choice(for id: String) -> AIModelChoice? {
        choices.first { $0.id == id }
    }
}
