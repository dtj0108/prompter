import Foundation
import Security

enum AmbitiousKeychainError: Error {
    case unexpectedStatus(OSStatus)
    case invalidData
}

enum AmbitiousKeychainStore {
    static var service: String {
#if DEBUG
        if ProcessInfo.processInfo.environment["PROMPTER_AMBITIOUS_REDIRECT_URI"]?.hasPrefix("prompter-lab://") == true {
            return "com.drew.prompter.ambitious.auth-lab"
        }
#endif
        return "com.drew.prompter.ambitious"
    }
    private static let account = "oauth-session-v1"

    static func loadSession() throws -> AmbitiousStoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AmbitiousKeychainError.unexpectedStatus(status) }
        guard let data = result as? Data,
              let session = try? JSONDecoder().decode(AmbitiousStoredSession.self, from: data) else {
            throw AmbitiousKeychainError.invalidData
        }
        return session
    }

    static func saveSession(_ session: AmbitiousStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AmbitiousKeychainError.unexpectedStatus(updateStatus)
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AmbitiousKeychainError.unexpectedStatus(addStatus)
        }
    }

    static func deleteSession() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AmbitiousKeychainError.unexpectedStatus(status)
        }
    }

    static func hasCachedIdentity() -> Bool {
        do { return try loadSession() != nil }
        catch { return false }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
