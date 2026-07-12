import Foundation

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var promptsDir: URL {
        let dir = appSupport.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    static var dictionaryFile: URL { appSupport.appendingPathComponent("dictionary.json") }
    static var snippetsFile: URL { appSupport.appendingPathComponent("snippets.json") }
    static var stylesFile: URL { appSupport.appendingPathComponent("styles.json") }
    static var historyFile: URL { appSupport.appendingPathComponent("history.jsonl") }
    static var promptModeFile: URL { promptsDir.appendingPathComponent("prompt-mode.md") }
    static var logFile: URL { appSupport.appendingPathComponent("prompter.log") }
    static var updateLogFile: URL { appSupport.appendingPathComponent("update.log") }
}

enum Log {
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "prompter.log")

    static func write(_ message: String) {
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: Paths.logFile)
                }
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }
}
