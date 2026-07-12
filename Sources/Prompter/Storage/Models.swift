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
    var showIdleIndicator: Bool = true
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

// MARK: - Tolerant decoding
// Missing keys fall back to defaults instead of failing the whole file, so app
// updates that add fields (or hand-edits that drop one) never wipe user data.

extension Config {
    private enum CodingKeys: String, CodingKey {
        case apiKey, cleanupModel, promptModel, claudeCLIPath, dictationHotkey, promptHotkey
        case llmCleanupEnabled, holdThresholdMs, pasteRestoreDelayMs, maxRecordingSec
        case soundsEnabled, showIdleIndicator, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? nil ?? d.apiKey
        cleanupModel = (try? c.decodeIfPresent(String.self, forKey: .cleanupModel)) ?? nil ?? d.cleanupModel
        promptModel = (try? c.decodeIfPresent(String.self, forKey: .promptModel)) ?? nil ?? d.promptModel
        claudeCLIPath = (try? c.decodeIfPresent(String.self, forKey: .claudeCLIPath)) ?? nil ?? d.claudeCLIPath
        dictationHotkey = (try? c.decodeIfPresent(String.self, forKey: .dictationHotkey)) ?? nil ?? d.dictationHotkey
        promptHotkey = (try? c.decodeIfPresent(String.self, forKey: .promptHotkey)) ?? nil ?? d.promptHotkey
        llmCleanupEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .llmCleanupEnabled)) ?? nil ?? d.llmCleanupEnabled
        holdThresholdMs = (try? c.decodeIfPresent(Int.self, forKey: .holdThresholdMs)) ?? nil ?? d.holdThresholdMs
        pasteRestoreDelayMs = (try? c.decodeIfPresent(Int.self, forKey: .pasteRestoreDelayMs)) ?? nil ?? d.pasteRestoreDelayMs
        maxRecordingSec = (try? c.decodeIfPresent(Int.self, forKey: .maxRecordingSec)) ?? nil ?? d.maxRecordingSec
        soundsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .soundsEnabled)) ?? nil ?? d.soundsEnabled
        showIdleIndicator = (try? c.decodeIfPresent(Bool.self, forKey: .showIdleIndicator)) ?? nil ?? d.showIdleIndicator
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? nil ?? d.launchAtLogin
    }
}

extension DictEntry {
    private enum CodingKeys: String, CodingKey { case id, phrase, soundsLike, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil ?? UUID()
        phrase = (try? c.decodeIfPresent(String.self, forKey: .phrase)) ?? nil ?? ""
        soundsLike = (try? c.decodeIfPresent([String].self, forKey: .soundsLike)) ?? nil ?? []
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil ?? ""
    }
}

extension ContextStyle {
    private enum CodingKeys: String, CodingKey { case id, name, appBundleIds, titleKeywords, instructions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? "custom-\(UUID().uuidString.prefix(6).lowercased())"
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? "Context"
        appBundleIds = (try? c.decodeIfPresent([String].self, forKey: .appBundleIds)) ?? nil ?? []
        titleKeywords = (try? c.decodeIfPresent([String].self, forKey: .titleKeywords)) ?? nil ?? []
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? nil ?? ""
    }
}

extension StyleConfig {
    private enum CodingKeys: String, CodingKey { case globalVoice, contexts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalVoice = (try? c.decodeIfPresent(String.self, forKey: .globalVoice)) ?? nil ?? StyleConfig.default.globalVoice
        contexts = (try? c.decodeIfPresent([ContextStyle].self, forKey: .contexts)) ?? nil ?? StyleConfig.default.contexts
        if !contexts.contains(where: { $0.id == "other" }) {
            contexts.append(StyleConfig.default.contexts.last!)
        }
    }
}

extension InsightEvent {
    private enum CodingKeys: String, CodingKey {
        case id, ts, app, bundleId, context, mode, audioSec, words, sttMs, llmMs, engine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil ?? UUID()
        ts = try c.decode(Date.self, forKey: .ts)
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? nil ?? ""
        bundleId = (try? c.decodeIfPresent(String.self, forKey: .bundleId)) ?? nil ?? ""
        context = (try? c.decodeIfPresent(String.self, forKey: .context)) ?? nil ?? ""
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil ?? "dictate"
        audioSec = (try? c.decodeIfPresent(Double.self, forKey: .audioSec)) ?? nil ?? 0
        words = (try? c.decodeIfPresent(Int.self, forKey: .words)) ?? nil ?? 0
        sttMs = (try? c.decodeIfPresent(Int.self, forKey: .sttMs)) ?? nil ?? 0
        llmMs = (try? c.decodeIfPresent(Int.self, forKey: .llmMs)) ?? nil ?? 0
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? nil ?? ""
    }
}
