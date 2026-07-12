import Foundation

// MARK: - Config

struct Config: Codable {
    var apiKey: String = ""
    var openRouterKey: String = ""
    var openRouterModel: String = "openai/gpt-5.6-luna"
    var cleanupModel: String = "claude-haiku-4-5-20251001"
    var promptModel: String = "claude-sonnet-5"
    var claudeCLIPath: String = ""
    var dictationHotkey: String = "rightOption"
    var promptHotkey: String = "rightCommand"
    var tapToLockEnabled: Bool = true
    var llmCleanupEnabled: Bool = true
    var holdThresholdMs: Int = 180
    var pasteRestoreDelayMs: Int = 800
    var maxRecordingSec: Int = 300
    var soundsEnabled: Bool = true
    var showIdleIndicator: Bool = true
    var launchAtLogin: Bool = false
    var onboardingDone: Bool = false

    static let `default` = Config()
}

// MARK: - Dictionary

struct DictEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var phrase: String
    var soundsLike: [String] = []
    var note: String = ""
}

// MARK: - Snippets

struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: String
    var expansion: String
}

// MARK: - Style

struct ContextStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var appBundleIds: [String] = []
    var titleKeywords: [String] = []
    var instructions: String = ""
    var tonePreset: String? = nil
}

struct StyleConfig: Codable {
    static let currentDefaultsVersion = 2

    var defaultsVersion: Int = currentDefaultsVersion
    var globalVoice: String
    var contexts: [ContextStyle]

    static let aiContext = ContextStyle(
        id: "ai",
        name: "AI apps",
        appBundleIds: [
            "com.openai.codex",
            "com.openai.chat",
            "com.anthropic.claudefordesktop",
            "com.anthropic.claude",
        ],
        titleKeywords: ["chatgpt", "claude", "codex", "gemini", "perplexity"],
        instructions: "Structure the request so an AI can act on it. Lead with the objective, preserve all context and constraints, and organize multi-part requests clearly. Do not answer the request or invent requirements.",
        tonePreset: "aiAssist"
    )

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
                instructions: "Casual and warm, like texting a friend. Contractions are fine. Keep it short. No greetings or sign-offs unless dictated. Light punctuation is okay.",
                tonePreset: "casual"
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
                instructions: "Clear, direct, professional but human. Get to the point in the first sentence. Bullets are fine if a list was dictated.",
                tonePreset: "formal"
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
                instructions: "Proper sentences and paragraphs. Professional but warm. Only add a greeting or sign-off if one was dictated. Break into short paragraphs where natural.",
                tonePreset: "formal"
            ),
            aiContext,
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
    var costUSD: Double = 0
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
        case apiKey, openRouterKey, openRouterModel, cleanupModel, promptModel, claudeCLIPath
        case dictationHotkey, promptHotkey, tapToLockEnabled
        case llmCleanupEnabled, holdThresholdMs, pasteRestoreDelayMs, maxRecordingSec
        case soundsEnabled, showIdleIndicator, launchAtLogin, onboardingDone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? nil ?? d.apiKey
        openRouterKey = (try? c.decodeIfPresent(String.self, forKey: .openRouterKey)) ?? nil ?? d.openRouterKey
        let storedOpenRouterModel = (try? c.decodeIfPresent(String.self, forKey: .openRouterModel)) ?? nil ?? d.openRouterModel
        // Move installations that still use the previous shipped default to
        // Luna, while preserving every explicitly selected/custom model.
        openRouterModel = storedOpenRouterModel == "google/gemini-2.5-flash-lite"
            ? d.openRouterModel
            : storedOpenRouterModel
        tapToLockEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .tapToLockEnabled)) ?? nil ?? d.tapToLockEnabled
        onboardingDone = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingDone)) ?? nil ?? d.onboardingDone
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

extension Snippet {
    private enum CodingKeys: String, CodingKey { case id, trigger, expansion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil ?? UUID()
        trigger = (try? c.decodeIfPresent(String.self, forKey: .trigger)) ?? nil ?? ""
        expansion = (try? c.decodeIfPresent(String.self, forKey: .expansion)) ?? nil ?? ""
    }
}

extension ContextStyle {
    private enum CodingKeys: String, CodingKey { case id, name, appBundleIds, titleKeywords, instructions, tonePreset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? "custom-\(UUID().uuidString.prefix(6).lowercased())"
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? "Context"
        appBundleIds = (try? c.decodeIfPresent([String].self, forKey: .appBundleIds)) ?? nil ?? []
        titleKeywords = (try? c.decodeIfPresent([String].self, forKey: .titleKeywords)) ?? nil ?? []
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? nil ?? ""
        tonePreset = (try? c.decodeIfPresent(String.self, forKey: .tonePreset)) ?? nil
        if tonePreset == nil,
           let shipped = StyleConfig.default.contexts.first(where: { $0.id == id }),
           shipped.instructions == instructions {
            tonePreset = shipped.tonePreset
        }
    }
}

extension StyleConfig {
    private enum CodingKeys: String, CodingKey { case defaultsVersion, globalVoice, contexts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = (try? c.decodeIfPresent(Int.self, forKey: .defaultsVersion)) ?? nil ?? 1
        defaultsVersion = Self.currentDefaultsVersion
        globalVoice = (try? c.decodeIfPresent(String.self, forKey: .globalVoice)) ?? nil ?? StyleConfig.default.globalVoice
        contexts = (try? c.decodeIfPresent([ContextStyle].self, forKey: .contexts)) ?? nil ?? StyleConfig.default.contexts
        // Add newly shipped categories once, without modifying any existing
        // context or re-adding one the user deliberately deletes later.
        if storedVersion < 2 && !contexts.contains(where: { $0.id == "ai" }) {
            let otherIndex = contexts.firstIndex(where: { $0.id == "other" }) ?? contexts.endIndex
            contexts.insert(Self.aiContext, at: otherIndex)
        }
        if !contexts.contains(where: { $0.id == "other" }) {
            contexts.append(StyleConfig.default.contexts.last!)
        }
    }
}

extension InsightEvent {
    private enum CodingKeys: String, CodingKey {
        case id, ts, app, bundleId, context, mode, audioSec, words, sttMs, llmMs, engine, costUSD
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
        costUSD = (try? c.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil ?? 0
    }
}
