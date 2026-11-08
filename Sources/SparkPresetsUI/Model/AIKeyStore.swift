import Foundation
import Security

/// Keeps the Ollama API key in the macOS Keychain instead of the plain-text preferences file. The entry is bound to
/// this Mac (not synced over iCloud Keychain, not moved to another Mac by a backup) and readable only while unlocked.
/// `bindToThisMac()` moves an entry written by an earlier version to these terms.
enum AIKeyStore {
    private static let service = "Spark Studio Ollama API Key"
    private static let account = "ollama.com"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    /// Stores the key; an empty key removes the entry.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Gives an entry from an earlier version the same terms as a new one. Does nothing when there is none.
    static func bindToThisMac() {
        let change = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemUpdate(query as CFDictionary, change as CFDictionary)
    }
}
