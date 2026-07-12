import AppKit
import Foundation
import SwiftUI

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
                print(reply.text)
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
                print(reply.text)
            }
            return true

        case "--test-prompt":
            guard args.count >= 3 else { return true }
            runBlocking {
                let dict = DictionaryStore.shared.entries.filter { !$0.phrase.isEmpty }
                let reply = try await LLMClient.shared.complete(
                    system: Prompts.promptModeSystemPrompt(dictionary: dict),
                    user: Prompts.promptModeUserPrompt(transcript: args[2]),
                    model: ConfigStore.shared.config.promptModel,
                    temperature: 0
                )
                print(reply.text)
            }
            return true

        case "--test-context":
            guard args.count >= 3 else {
                FileHandle.standardError.write(Data("usage: Prompter --test-context <bundle-id> [window-title]\n".utf8))
                return true
            }
            let style = StyleStore.shared.style
            let title = args.count >= 4 ? args[3] : ""
            let fallback = style.contexts.first(where: { $0.id == "other" })
            let context = ContextDetector.match(bundleId: args[2], title: title, contexts: style.contexts) ?? fallback
            if let context {
                print("\(context.id)\t\(context.name)\t\(context.instructions)")
            }
            return true

        case "--render-style":
            guard args.count >= 3 else {
                FileHandle.standardError.write(Data("usage: Prompter --render-style <png-path>\n".utf8))
                return true
            }
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                let content = StyleView()
                    .environmentObject(StyleStore.shared)
                    .frame(width: 880, height: 980)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: 880, height: 980)
                host.appearance = NSAppearance(named: .aqua)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    FileHandle.standardError.write(Data("failed to render Style view\n".utf8))
                    return
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
                do {
                    try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
                    print(args[2])
                } catch {
                    FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                }
            }
            return true

        case "--install-update":
            guard args.count >= 6, let parentPID = pid_t(args[5]) else {
                FileHandle.standardError.write(Data("invalid update installer arguments\n".utf8))
                return true
            }
            do {
                try UpdateInstaller.install(
                    sourceApp: URL(fileURLWithPath: args[2], isDirectory: true),
                    targetApp: URL(fileURLWithPath: args[3], isDirectory: true),
                    temporaryRoot: URL(fileURLWithPath: args[4], isDirectory: true),
                    parentPID: parentPID
                )
            } catch {
                FileHandle.standardError.write(Data("update install failed: \(error)\n".utf8))
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
