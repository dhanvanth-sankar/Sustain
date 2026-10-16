import Foundation
import Security

/// A minimal wrapper around the Keychain Services API for the one thing this
/// app now needs it for: persisting the Supabase auth session (access +
/// refresh tokens) across launches. Deliberately not `UserDefaults` — those
/// tokens are real bearer credentials for a user's account and cloud data,
/// not app preferences, and `UserDefaults`' backing plist is readable by
/// anything with filesystem access to the app's container (e.g. an unencrypted
/// local backup). Keychain items are encrypted at rest and tied to the
/// device's data-protection class.
///
/// `kSecAttrAccessibleAfterFirstUnlock` (rather than the default
/// `WhenUnlocked`) is deliberate: this app fires local notifications
/// (`NotificationManager`) and could plausibly run brief background work
/// while the device is locked, and a session that silently failed to read
/// until the user next unlocked their phone would be a confusing, hard-to-
/// reproduce bug. `AfterFirstUnlock` still never syncs to iCloud Keychain or
/// survives a restore to a different device — exactly the boundary a
/// per-device session token should have.
enum KeychainHelper {
    private static let service = "com.sustainapp.glp1.auth"

    static func set(_ data: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func removeValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
