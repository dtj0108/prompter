import Foundation

enum LLMError: Error, LocalizedError {
    case noBackend
    case cliNotFound
    case cliNotLoggedIn
    case cliFailed(String)
    case apiFailed(String)
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noBackend: return "No AI backend — add an OpenRouter API key in Settings (or install the claude CLI)."
        case .cliNotFound: return "claude CLI not found."
        case .cliNotLoggedIn: return "claude CLI isn't logged in — run “claude /login” in Terminal once, or add an OpenRouter key in Settings."
        case .cliFailed(let msg): return "claude CLI failed: \(msg)"
        case .apiFailed(let msg): return "API failed: \(msg)"
        case .timeout: return "The model took too long to respond."
        case .emptyResponse: return "The model returned an empty response."
        }
    }
}

/// Talks to an LLM via OpenRouter (if an API key is configured) or falls back to
/// the locally installed `claude` CLI (billed to the user's existing subscription).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

struct LLMResult {
    var text: String
    /// Actual USD cost of this request (OpenRouter reports it per call; 0 for CLI).
    var costUSD: Double = 0
}

final class LLMClient {
    static let shared = LLMClient()

    private var cachedCLIPath: String?
    private var cachedForConfiguredPath: String?

    /// If the chosen model errors or is rate-limited, OpenRouter silently retries
    /// down this list (verified cheap + good at rewrite-style instruction following).
    static let fallbackModels = [
        "openai/gpt-oss-120b",
        "qwen/qwen3-30b-a3b-instruct-2507",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    /// `model` is the claude CLI model; when OpenRouter is active the configured
    /// OpenRouter model is used instead (one model for everything — simpler).
    func complete(system: String, user: String, model: String, timeout: TimeInterval = 90) async throws -> LLMResult {
        let orKey = ConfigStore.shared.config.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !orKey.isEmpty {
            let orModel = ConfigStore.shared.config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await completeViaOpenRouter(
                system: system, user: user,
                model: orModel.isEmpty ? Config.default.openRouterModel : orModel,
                apiKey: orKey, timeout: timeout
            )
        }
        let text = try await completeViaCLI(system: system, user: user, model: model, timeout: timeout)
        return LLMResult(text: text, costUSD: 0)
    }

    var backendDescription: String {
        let orKey = ConfigStore.shared.config.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !orKey.isEmpty { return "OpenRouter (\(ConfigStore.shared.config.openRouterModel))" }
        if let path = locateCLI() { return "claude CLI (\(path))" }
        return "none found"
    }

    // MARK: - OpenRouter

    private func completeViaOpenRouter(system: String, user: String, model: String, apiKey: String, timeout: TimeInterval) async throws -> LLMResult {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional attribution headers (shown on OpenRouter's activity page).
        request.setValue("https://github.com/drewbaskin/prompter", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Prompter", forHTTPHeaderField: "X-OpenRouter-Title")

        var body: [String: Any] = [
            "model": model,
            // If the chosen model is down or rate-limited, OpenRouter tries these.
            "models": Self.fallbackModels.filter { $0 != model },
            "max_completion_tokens": 8000,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // Reasoning-by-default models burn tokens/latency thinking about a rewrite job.
        if model.contains("gpt-oss") || model.contains("gpt-5") || model.contains("thinking") {
            body["reasoning"] = ["effort": "low"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.apiFailed("no response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let apiMsg = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiFailed("OpenRouter \(http.statusCode): \(String(apiMsg.prefix(300)))")
        }
        // Some upstream failures still come back 200 with an error object.
        if let err = (json?["error"] as? [String: Any])?["message"] as? String {
            throw LLMError.apiFailed("OpenRouter: \(String(err.prefix(300)))")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.apiFailed("unexpected OpenRouter response shape")
        }
        let cost = ((json?["usage"] as? [String: Any])?["cost"] as? Double) ?? 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return LLMResult(text: trimmed, costUSD: cost)
    }

    // MARK: - claude CLI

    func locateCLI() -> String? {
        let configured = ConfigStore.shared.config.claudeCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured != cachedForConfiguredPath {
            cachedCLIPath = nil // settings changed — re-resolve
        }
        if let cached = cachedCLIPath, FileManager.default.isExecutableFile(atPath: cached) { return cached }
        var candidates: [String] = []
        if !configured.isEmpty { candidates.append((configured as NSString).expandingTildeInPath) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cachedCLIPath = path
            cachedForConfiguredPath = configured
            return path
        }
        return nil
    }

    private func completeViaCLI(system: String, user: String, model: String, timeout: TimeInterval) async throws -> String {
        guard let cli = locateCLI() else { throw LLMError.cliNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "-p",
            "--model", model,
            "--output-format", "text",
            "--max-turns", "1",
            "--tools", "",
            "--system-prompt", system,
        ]
        // Run from the app-support dir so no project CLAUDE.md gets pulled into context.
        process.currentDirectoryURL = Paths.appSupport
        process.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(user.data(using: .utf8) ?? Data())
        try? stdin.fileHandleForWriting.close()

        // Read output on background threads to avoid pipe-buffer deadlock.
        let outTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

        let timedOut = LockedFlag()
        let pid = process.processIdentifier
        let finished: Bool = await withCheckedContinuation { continuation in
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: true)
            }
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    timedOut.set()
                    process.terminate()
                    // If SIGTERM is ignored, escalate so complete() can never hang forever.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
        }
        _ = finished

        let outData = await outTask.value
        let errData = await errTask.value

        guard process.terminationStatus == 0 else {
            if timedOut.get() { throw LLMError.timeout }
            let combined = (String(data: outData, encoding: .utf8) ?? "") + " " + (String(data: errData, encoding: .utf8) ?? "")
            if combined.localizedCaseInsensitiveContains("not logged in") {
                throw LLMError.cliNotLoggedIn
            }
            if process.terminationReason == .uncaughtSignal {
                throw LLMError.cliFailed("claude CLI killed by signal \(process.terminationStatus)")
            }
            throw LLMError.cliFailed(String(combined.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
        }
        let text = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
