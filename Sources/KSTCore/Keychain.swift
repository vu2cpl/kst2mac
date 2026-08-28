import Foundation
import Security

/// Minimal Keychain wrapper for the chat password.
///
/// The password crosses the wire in clear (the chat has no TLS on 23000),
/// so it should be one you use nowhere else — but that is no reason to
/// also leave it sitting in a preferences plist.
public enum Keychain {

    public static let service = "net.vu2cpl.kst2mac.on4kst"

    public static func setPassword(_ password: String, account: String) throws {
        let account = account.uppercased()
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Upsert: try update, fall back to add.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// - Parameter service: overridable so a rename can carry the
    ///   password over from the previous bundle identifier's namespace.
    public static func password(account: String, service: String = Keychain.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uppercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func removePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uppercased(),
        ]
        SecItemDelete(query as CFDictionary)
    }

    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}
