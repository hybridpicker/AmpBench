import Foundation
import Security

/// Where key entries are kept, by service name: the macOS Keychain, or a stand-in in tests.
protocol KeyEntries {
    /// The entry's value, or nil when there is none.
    func value(service: String) -> String?
    /// Writes the entry, replacing one that is there.
    func store(_ value: String, service: String)
}

/// The macOS Keychain. An entry is bound to this Mac (not synced over iCloud Keychain, not moved to another Mac by a
/// backup) and readable only while unlocked.
struct KeychainEntries: KeyEntries {
    let account: String

    func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func value(service: String) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func store(_ value: String, service: String) {
        SecItemDelete(query(service) as CFDictionary)
        var q = query(service)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Keeps the Ollama API key in the macOS Keychain instead of the plain-text preferences file.
/// `bindToThisMac()` moves an entry written by an earlier version to the terms of `KeychainEntries`.
enum AIKeyStore {
    static let service = "AmpBench Ollama API Key"
    /// The entry's name while the app was called Spark Studio.
    static let earlierService = "Spark Studio Ollama API Key"
    private static let account = "ollama.com"
    private static let keychain = KeychainEntries(account: account)

    static func load() -> String {
        keychain.value(service: service) ?? ""
    }

    /// Stores the key; an empty key removes the entry.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(keychain.query(service) as CFDictionary)
            return
        }
        keychain.store(trimmed, service: service)
    }

    /// Carries the key over from the entry Spark Studio wrote, once: only while there is no entry under the new
    /// name. The earlier entry stays where it is. Returns true when a key was carried over. The key itself is never
    /// logged or shown.
    @discardableResult
    static func carryOverFromSparkStudio(in entries: KeyEntries? = nil) -> Bool {
        let entries = entries ?? keychain
        guard entries.value(service: service) == nil,
              let earlier = entries.value(service: earlierService)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !earlier.isEmpty else { return false }
        entries.store(earlier, service: service)
        return true
    }

    /// Gives an entry from an earlier version the same terms as a new one. Does nothing when there is none.
    static func bindToThisMac() {
        let change = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemUpdate(keychain.query(service) as CFDictionary, change as CFDictionary)
    }
}
