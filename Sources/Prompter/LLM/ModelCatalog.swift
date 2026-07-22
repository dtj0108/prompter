import Foundation

struct AIModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

enum TranscriptionModelCatalog {
    static let choices: [AIModelChoice] = [
        AIModelChoice(
            id: "openai/gpt-4o-transcribe",
            name: "GPT-4o Transcribe",
            detail: "Highest-quality OpenAI STT"
        ),
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
        AIModelChoice(id: "x-ai/grok-build-0.1", name: "Grok Build 0.1", detail: "Fast agentic coding"),
        AIModelChoice(id: "anthropic/claude-sonnet-5", name: "Sonnet 5", detail: "Claude Sonnet 5"),
        AIModelChoice(id: "google/gemini-3.6-flash", name: "Gemini 3.6 Flash", detail: "Newest Gemini Flash"),
        AIModelChoice(id: "google/gemini-3.5-flash", name: "Gemini 3.5 Flash", detail: "Fast coding & reasoning"),
        AIModelChoice(id: "google/gemini-3.1-flash-lite", name: "Gemini 3.1 Flash Lite", detail: "Fast & inexpensive"),
        AIModelChoice(id: "google/gemini-2.0-flash-001", name: "Gemini 2.0 Flash", detail: "Legacy fast multimodal"),
    ]

    static func choice(for id: String) -> AIModelChoice? {
        choices.first { $0.id == id }
    }
}
