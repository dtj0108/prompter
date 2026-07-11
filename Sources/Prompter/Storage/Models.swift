import Foundation

// MARK: - Config

struct Config: Codable {
    var apiKey: String = ""
    var cleanupModel: String = "claude-haiku-4-5-20251001"
    var promptModel: String = "claude-sonnet-5"
    var claudeCLIPath: String = ""
    var dictationHotkey: String = "rightOption"
    var promptHotkey: String = "rightCommand"
    var llmCleanupEnabled: Bool = true
    var holdThresholdMs: Int = 180
    var pasteRestoreDelayMs: Int = 800
    var maxRecordingSec: Int = 300
    var soundsEnabled: Bool = true
    var launchAtLogin: Bool = false

    static let `default` = Config()
}

// MARK: - Dictionary

struct DictEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var phrase: String
    var soundsLike: [String] = []
    var note: String = ""
}

// MARK: - Style

struct ContextStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var appBundleIds: [String] = []
    var titleKeywords: [String] = []
    var instructions: String = ""
}

struct StyleConfig: Codable {
    var globalVoice: String
    var contexts: [ContextStyle]

    static let `default` = StyleConfig(
        globalVoice: "Direct and plainspoken. Short sentences. No corporate fluff, no filler words like \"just\" or \"I wanted to\". Sounds like a founder talking, not a press release.",
        contexts: [
            ContextStyle(
                id: "personal",
                name: "Personal messages",
                appBundleIds: [
                    "com.apple.MobileSMS",
                    "net.whatsapp.WhatsApp",
                    "ru.keepcoder.Telegram",
                    "com.hnc.Discord",
                ],
                titleKeywords: ["whatsapp", "messenger"],
                instructions: "Casual and warm, like texting a friend. Contractions are fine. Keep it short. No greetings or sign-offs unless dictated. Light punctuation is okay."
            ),
            ContextStyle(
                id: "work",
                name: "Work messages",
                appBundleIds: [
                    "com.tinyspeck.slackmacgap",
                    "com.microsoft.teams2",
                    "notion.id",
                    "com.linear",
                ],
                titleKeywords: ["slack", "notion", "linear", "asana", "monday.com"],
                instructions: "Clear, direct, professional but human. Get to the point in the first sentence. Bullets are fine if a list was dictated."
            ),
            ContextStyle(
                id: "email",
                name: "Email",
                appBundleIds: [
                    "com.apple.mail",
                    "com.microsoft.Outlook",
                    "com.readdle.smartemail-Mac",
                    "com.superhuman.electron",
                ],
                titleKeywords: ["gmail", "inbox", "mail.google.com", "outlook", "superhuman", "compose"],
                instructions: "Proper sentences and paragraphs. Professional but warm. Only add a greeting or sign-off if one was dictated. Break into short paragraphs where natural."
            ),
            ContextStyle(
                id: "other",
                name: "Everything else",
                appBundleIds: [],
                titleKeywords: [],
                instructions: "Neutral, clean writing. Match whatever tone the dictation itself carries."
            ),
        ]
    )
}

// MARK: - Insights

struct InsightEvent: Codable, Identifiable {
    var id: UUID = UUID()
    var ts: Date
    var app: String
    var bundleId: String
    var context: String
    var mode: String // "dictate" | "prompt"
    var audioSec: Double
    var words: Int
    var sttMs: Int
    var llmMs: Int
    var engine: String
}

// MARK: - Modes

enum DictationMode: String {
    case dictate
    case prompt
}
