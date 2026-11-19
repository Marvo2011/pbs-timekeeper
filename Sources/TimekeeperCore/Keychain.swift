import Foundation
import Security

/// Passwords as generic passwords in the login keychain.
public enum Keychain {
    public static let service = "io.github.marvo2011.pbs-timekeeper"

    public enum Account: String, Sendable {
        case serverPassword = "server-password"
        case encryptionPassword = "encryption-password"
    }

    static func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    public static func get(_ account: Account) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the password, an empty one removes the item.
    public static func set(_ value: String, for account: Account) throws {
        let base = query(account)
        if value.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "PBS Timekeeper (\(account.rawValue))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public static var secrets: Secrets {
        Secrets(password: get(.serverPassword), encryptionPassword: get(.encryptionPassword))
    }
}

public struct KeychainError: Error, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain: \(message)"
    }
}
