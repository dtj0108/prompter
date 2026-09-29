import Foundation
import Testing
@testable import Prompter

@Suite("GPT Live Transcribe")
struct OpenAIRealtimeTranscriberTests {
    @Test("Live typing is opt-in and obsolete engine settings do not survive encoding")
    func configMigration() throws {
        let old = Data(#"{"useOpenAITranscription":false,"openAITranscriptionModel":"other","useOpenRouterTranscription":true,"openAIKey":"example-key","dictationHotkey":"rightControl","onboardingDone":true}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: old)
        #expect(!config.liveTypingEnabled)
        #expect(config.openAIKey == "example-key")
        #expect(config.dictationHotkey == "rightControl")
        #expect(config.onboardingDone)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["useOpenAITranscription"] == nil)
        #expect(encoded["openAITranscriptionModel"] == nil)
        #expect(encoded["useOpenRouterTranscription"] == nil)
        #expect(OpenAIRealtimeTranscriber.defaultModel == "gpt-live-transcribe")
    }

    @Test("Live typing preference round-trips and malformed values use the default")
    func liveTypingPersistence() throws {
        var config = Config()
        config.liveTypingEnabled = true
        #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config)).liveTypingEnabled)
        #expect(try !JSONDecoder().decode(Config.self, from: Data(#"{"liveTypingEnabled":"yes"}"#.utf8)).liveTypingEnabled)
    }

    @Test("Deltas accumulate once and final text replaces the draft for the same item")
    func transcriptEvents() {
        let engine = OpenAIRealtimeTranscriber()
        var updates: [String] = []
        engine.onTranscript = { updates.append($0) }
        send(engine, type: "delta", id: "1", text: "Meet on Tues")
        send(engine, type: "delta", id: "1", text: "Meet on Tues")
        send(engine, type: "delta", id: "2", text: "day")
        send(engine, type: "delta", id: "3", text: "wrong turn", item: "other")
        send(engine, type: "completed", id: "4", text: "Meet on Wednesday.")
        send(engine, type: "delta", id: "5", text: "late")
        #expect(updates == ["Meet on Tues", "Meet on Tuesday", "Meet on Wednesday."])
        #expect(engine.availableText == "Meet on Wednesday.")
    }

    @Test("A failed stream returns received words instead of changing models")
    func recoverPartial() async throws {
        let engine = OpenAIRealtimeTranscriber()
        var failures = 0
        engine.onFailure = { failures += 1 }
        send(engine, type: "delta", id: "1", text: "Keep these words")
        engine.handleServerEvent(Data(#"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"Connection interrupted"}}"#.utf8))
        let result = try await engine.finishResult()
        #expect(result.text == "Keep these words")
        #expect(result.isPartial)
        #expect(failures == 1)
    }

    @Test("An empty completion preserves prior deltas")
    func emptyCompletion() async throws {
        let engine = OpenAIRealtimeTranscriber()
        send(engine, type: "delta", id: "1", text: "Keep me")
        send(engine, type: "completed", id: "2", text: "")
        #expect(engine.availableText == "Keep me")
        #expect(try await engine.finishResult().isPartial)
    }

    @Test("Cancellation ignores late network events and never returns recovered text")
    func cancellation() async {
        let engine = OpenAIRealtimeTranscriber()
        send(engine, type: "delta", id: "1", text: "Original")
        engine.cancel()
        send(engine, type: "delta", id: "2", text: " late")
        #expect(engine.availableText == "Original")
        await #expect(throws: (any Error).self) { try await engine.finishResult() }
    }

    @Test("Reads a plain or quoted key without exposing it")
    func environmentFileParsing() {
        #expect(OpenAICredentials.apiKey(fromEnvironmentFileContents: "OTHER=value\nOPENAI_API_KEY=example-plain\n") == "example-plain")
        #expect(OpenAICredentials.apiKey(fromEnvironmentFileContents: "OPENAI_API_KEY=\"example-quoted\"\n") == "example-quoted")
    }

    @Test("Estimates duration billing")
    func durationCost() {
        #expect(OpenAIRealtimeTranscriber.estimatedCostUSD(audioSeconds: 60) == 0.017)
        #expect(OpenAIRealtimeTranscriber.estimatedCostUSD(audioSeconds: -1) == 0)
    }

    private func send(_ engine: OpenAIRealtimeTranscriber, type: String, id: String, text: String, item: String = "utterance") {
        let event = ["type": "conversation.item.input_audio_transcription.\(type)", "event_id": id,
                     "item_id": item, type == "delta" ? "delta" : "transcript": text]
        engine.handleServerEvent(try! JSONSerialization.data(withJSONObject: event))
    }
}
