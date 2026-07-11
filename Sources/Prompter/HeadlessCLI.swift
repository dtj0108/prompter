import Foundation

/// Command-line test entry points so the pipeline can be verified without mic/GUI.
enum HeadlessCLI {

    /// Returns true if a headless command was handled (caller should exit).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }

        switch args[1] {
        case "--transcribe":
            guard args.count >= 3 else {
                FileHandle.standardError.write(Data("usage: Prompter --transcribe <audio-file>\n".utf8))
                return true
            }
            runBlocking {
                let url = URL(fileURLWithPath: args[2])
                let text = try await SpeechAnalyzerEngine.transcribeFile(url)
                print(text)
            }
            return true

        case "--test-llm":
            runBlocking {
                let reply = try await LLMClient.shared.complete(
                    system: "Reply with exactly: PROMPTER-OK",
                    user: "Health check.",
                    model: ConfigStore.shared.config.cleanupModel
                )
                print(reply)
            }
            return true

        case "--test-cleanup":
            guard args.count >= 3 else { return true }
            runBlocking {
                let dict = DictionaryStore.shared.entries.filter { !$0.phrase.isEmpty }
                let system = Prompts.cleanupSystemPrompt(
                    context: FrontContext.unknown,
                    style: StyleStore.shared.style,
                    dictionary: dict
                )
                let reply = try await LLMClient.shared.complete(
                    system: system,
                    user: Prompts.cleanupUserPrompt(transcript: args[2]),
                    model: ConfigStore.shared.config.cleanupModel
                )
                print(reply)
            }
            return true

        case "--test-prompt":
            guard args.count >= 3 else { return true }
            runBlocking {
                let dict = DictionaryStore.shared.entries.filter { !$0.phrase.isEmpty }
                let reply = try await LLMClient.shared.complete(
                    system: Prompts.promptModeSystemPrompt(dictionary: dict),
                    user: Prompts.promptModeUserPrompt(transcript: args[2]),
                    model: ConfigStore.shared.config.promptModel
                )
                print(reply)
            }
            return true

        default:
            return false
        }
    }

    private static func runBlocking(_ body: @escaping () async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await body()
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
