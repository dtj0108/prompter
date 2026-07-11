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
        case .noBackend: return "No Claude backend available (no API key and claude CLI not found)."
        case .cliNotFound: return "claude CLI not found."
        case .cliNotLoggedIn: return "claude CLI isn't logged in — run “claude /login” in Terminal once, or add an API key in Settings."
        case .cliFailed(let msg): return "claude CLI failed: \(msg)"
        case .apiFailed(let msg): return "Anthropic API failed: \(msg)"
        case .timeout: return "The model took too long to respond."
        case .emptyResponse: return "The model returned an empty response."
        }
    }
}

/// Talks to Claude either via the Anthropic API (if an API key is configured)
/// or via the locally installed `claude` CLI (billed to the user's existing subscription).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class LLMClient {
    static let shared = LLMClient()

    private var cachedCLIPath: String?
    private var cachedForConfiguredPath: String?

    func complete(system: String, user: String, model: String, timeout: TimeInterval = 90) async throws -> String {
        let apiKey = ConfigStore.shared.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            return try await completeViaAPI(system: system, user: user, model: model, apiKey: apiKey, timeout: timeout)
        }
        return try await completeViaCLI(system: system, user: user, model: model, timeout: timeout)
    }

    var backendDescription: String {
        let apiKey = ConfigStore.shared.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty { return "Anthropic API" }
        if let path = locateCLI() { return "claude CLI (\(path))" }
        return "none found"
    }

    // MARK: - Anthropic API

    private func completeViaAPI(system: String, user: String, model: String, apiKey: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.apiFailed("no response") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw LLMError.apiFailed(String(msg.prefix(500)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMError.apiFailed("unexpected response shape")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
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
