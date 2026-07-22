import Testing
@testable import Prompter

@Suite("OpenRouter model catalog")
struct ModelCatalogTests {
    @Test("Includes GPT-4o Transcribe")
    func gpt4oTranscribe() {
        let choice = TranscriptionModelCatalog.choice(for: "openai/gpt-4o-transcribe")
        #expect(choice?.name == "GPT-4o Transcribe")
    }

    @Test("Includes current requested model IDs")
    func requestedModels() {
        let expected = [
            "x-ai/grok-build-0.1",
            "google/gemini-3.6-flash",
            "google/gemini-3.5-flash",
            "google/gemini-2.0-flash-001",
        ]

        for id in expected {
            #expect(AIModelCatalog.choice(for: id) != nil)
        }
    }

    @Test("Displays Claude Sonnet 5 correctly")
    func sonnetLabel() {
        #expect(AIModelCatalog.choice(for: "anthropic/claude-sonnet-5")?.name == "Sonnet 5")
    }
}
