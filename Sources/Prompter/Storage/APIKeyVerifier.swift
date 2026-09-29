import CryptoKit
import Foundation

enum APIKeyProvider: String, CaseIterable {
    case openAI
    case openRouter
}

/// Tests API keys against the real services and remembers which exact key passed.
/// Only a SHA-256 fingerprint of a passing key is kept (in UserDefaults), so a
/// verified key stays verified across launches and any edit makes it untested.
@MainActor
final class APIKeyVerifier: ObservableObject {
    static let shared = APIKeyVerifier()

    enum Status: Equatable {
        case missing
        case untested
        case checking
        case verified
        case failed(String)
    }

    @Published private(set) var statuses: [APIKeyProvider: Status] = [:]
    private var checks: [APIKeyProvider: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard

    private init() {
        for provider in APIKeyProvider.allCases { refresh(provider) }
    }

    func status(_ provider: APIKeyProvider) -> Status { statuses[provider] ?? .missing }

    func isVerified(_ provider: APIKeyProvider) -> Bool { status(provider) == .verified }

    /// Call whenever the key text changes: a different key is untested until checked.
    func refresh(_ provider: APIKeyProvider) {
        let key = currentKey(provider)
        checks[provider]?.cancel()
        checks[provider] = nil
        if key.isEmpty {
            statuses[provider] = .missing
        } else if defaults.string(forKey: fingerprintKey(provider)) == Self.fingerprint(key) {
            statuses[provider] = .verified
        } else {
            statuses[provider] = .untested
        }
    }

    func check(_ provider: APIKeyProvider) {
        let key = currentKey(provider)
        guard !key.isEmpty else {
            statuses[provider] = .missing
            return
        }
        checks[provider]?.cancel()
        statuses[provider] = .checking
        checks[provider] = Task { [weak self] in
            let failure: String?
            switch provider {
            case .openAI: failure = await OpenAIRealtimeTranscriber.checkKey(key)
            case .openRouter: failure = await Self.checkOpenRouterKey(key)
            }
            guard !Task.isCancelled, let self, self.currentKey(provider) == key else { return }
            if let failure {
                self.defaults.removeObject(forKey: self.fingerprintKey(provider))
                self.statuses[provider] = .failed(failure)
                Log.write("\(provider.rawValue) key check failed: \(failure)")
            } else {
                self.defaults.set(Self.fingerprint(key), forKey: self.fingerprintKey(provider))
                self.statuses[provider] = .verified
                Log.write("\(provider.rawValue) key check passed")
            }
            self.checks[provider] = nil
        }
    }

    private func currentKey(_ provider: APIKeyProvider) -> String {
        let config = ConfigStore.shared.config
        let raw = provider == .openAI ? config.openAIKey : config.openRouterKey
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fingerprintKey(_ provider: APIKeyProvider) -> String {
        "verifiedKeyFingerprint.\(provider.rawValue)"
    }

    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// OpenRouter's key endpoint answers 200 for any valid key and costs nothing.
    nonisolated static func checkOpenRouterKey(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return openRouterMessage(status: status)
        } catch {
            return "Can't reach OpenRouter — check your internet connection"
        }
    }

    nonisolated static func openRouterMessage(status: Int) -> String? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return "OpenRouter rejected this key — check it at openrouter.ai/keys"
        case 402: return "OpenRouter account is out of credit — add credit at openrouter.ai"
        case 429: return "OpenRouter rate limit reached — wait a moment and try again"
        default: return "OpenRouter couldn't check this key (HTTP \(status)) — try again"
        }
    }
}
