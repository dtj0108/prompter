import Foundation
import Combine

private func loadJSON<T: Codable>(_ url: URL, fallback: T) -> T {
    guard let data = try? Data(contentsOf: url) else { return fallback }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(T.self, from: data)
    } catch {
        // Never let a bad file get silently overwritten by defaults on the next
        // save — park a copy first so nothing is ever lost.
        Log.write("failed to decode \(url.lastPathComponent): \(error) — backing it up")
        let backup = url.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.copyItem(at: url, to: backup)
        return fallback
    }
}

private func saveJSON<T: Codable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Config

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    @Published var config: Config {
        didSet { saveJSON(config, to: Paths.configFile) }
    }
    private init() {
        config = loadJSON(Paths.configFile, fallback: Config.default)
    }
}

// MARK: - Dictionary

final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()
    @Published var entries: [DictEntry] {
        didSet { saveJSON(entries, to: Paths.dictionaryFile) }
    }
    private init() {
        let seed: [DictEntry] = [
            DictEntry(phrase: "Hormozi", soundsLike: ["Hermosi", "Her Mozi", "Ramosi", "Hormosey"]),
            DictEntry(phrase: "Contractor Calls", soundsLike: ["contractor calls"]),
            DictEntry(phrase: "contractorcalls.ai", soundsLike: ["contractor calls dot AI", "contractor calls dot A I"]),
            DictEntry(phrase: "GSO", soundsLike: ["G S O", "GSL"], note: "Grand Slam Offer"),
            DictEntry(phrase: "Wispr Flow", soundsLike: ["whisper flow", "wisper flow"]),
        ]
        if FileManager.default.fileExists(atPath: Paths.dictionaryFile.path) {
            entries = loadJSON(Paths.dictionaryFile, fallback: seed)
        } else {
            entries = seed
            saveJSON(seed, to: Paths.dictionaryFile)
        }
    }

    /// Regex-based fallback correction used when the LLM pass is disabled or fails.
    func applyRawCorrections(to text: String) -> String {
        var result = text
        for entry in entries {
            for wrong in entry.soundsLike where !wrong.isEmpty {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    result = re.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: NSRegularExpression.escapedTemplate(for: entry.phrase)
                    )
                }
            }
        }
        return result
    }
}

// MARK: - Snippets

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    @Published var snippets: [Snippet] {
        didSet { saveJSON(snippets, to: Paths.snippetsFile) }
    }

    private init() {
        let seed: [Snippet] = [
            Snippet(trigger: "my email address", expansion: "hello@contractorcalls.ai"),
            Snippet(trigger: "my website", expansion: "https://contractorcalls.ai"),
        ]
        if FileManager.default.fileExists(atPath: Paths.snippetsFile.path) {
            snippets = loadJSON(Paths.snippetsFile, fallback: seed)
        } else {
            snippets = seed
            saveJSON(seed, to: Paths.snippetsFile)
        }
    }

    /// If the whole utterance IS a snippet trigger ("my email address"), return it —
    /// the expansion gets pasted directly, no LLM round-trip needed.
    func exactMatch(for transcript: String) -> Snippet? {
        let normalized = Self.normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        return snippets.first {
            !$0.expansion.isEmpty && Self.normalize($0.trigger) == normalized
        }
    }

    /// Lowercased, punctuation stripped, whitespace collapsed — so "My email address."
    /// spoken aloud matches the trigger "my email address".
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

// MARK: - Style

final class StyleStore: ObservableObject {
    static let shared = StyleStore()
    @Published var style: StyleConfig {
        didSet { saveJSON(style, to: Paths.stylesFile) }
    }
    private init() {
        if FileManager.default.fileExists(atPath: Paths.stylesFile.path) {
            style = loadJSON(Paths.stylesFile, fallback: StyleConfig.default)
        } else {
            style = StyleConfig.default
            saveJSON(StyleConfig.default, to: Paths.stylesFile)
        }
    }
}

// MARK: - Insights

final class InsightsStore: ObservableObject {
    static let shared = InsightsStore()
    @Published private(set) var events: [InsightEvent] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: Paths.historyFile),
              let text = String(data: data, encoding: .utf8) else {
            events = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(InsightEvent.self, from: Data(line.utf8))
        }
    }

    func append(_ event: InsightEvent) {
        DispatchQueue.main.async { self.events.append(event) }
        guard let data = try? encoder.encode(event) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: Paths.historyFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: Paths.historyFile)
        }
    }

    // MARK: Aggregates

    struct DayStat: Identifiable {
        var id: String { label }
        var date: Date
        var label: String
        var words: Int
    }

    var totalWords: Int { events.reduce(0) { $0 + $1.words } }

    var todayWords: Int {
        let cal = Calendar.current
        return events.filter { cal.isDateInToday($0.ts) }.reduce(0) { $0 + $1.words }
    }

    var weekWords: Int {
        guard let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) else { return 0 }
        return events.filter { $0.ts >= start }.reduce(0) { $0 + $1.words }
    }

    /// Actual AI spend (reported per-request by OpenRouter; 0 when on the claude CLI).
    var totalCostUSD: Double { events.reduce(0) { $0 + $1.costUSD } }

    /// Estimated seconds saved vs typing at 40 WPM.
    var totalTimeSavedSec: Double {
        events.reduce(0) { acc, e in
            acc + max(0, Double(e.words) / 40.0 * 60.0 - e.audioSec)
        }
    }

    var streakDays: Int {
        let cal = Calendar.current
        let days = Set(events.map { cal.startOfDay(for: $0.ts) })
        guard !days.isEmpty else { return 0 }
        var streak = 0
        var cursor = cal.startOfDay(for: Date())
        // Today counts if present; otherwise streak may still be alive from yesterday.
        if !days.contains(cursor) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor), days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    func last14Days() -> [DayStat] {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "M/d"
        var byDay: [Date: Int] = [:]
        for e in events {
            byDay[cal.startOfDay(for: e.ts), default: 0] += e.words
        }
        var stats: [DayStat] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())) else { continue }
            stats.append(DayStat(date: day, label: df.string(from: day), words: byDay[day] ?? 0))
        }
        return stats
    }

    func topApps(limit: Int = 6) -> [(app: String, words: Int)] {
        var byApp: [String: Int] = [:]
        for e in events { byApp[e.app.isEmpty ? "Unknown" : e.app, default: 0] += e.words }
        return byApp.sorted { $0.value > $1.value }.prefix(limit).map { (app: $0.key, words: $0.value) }
    }
}
