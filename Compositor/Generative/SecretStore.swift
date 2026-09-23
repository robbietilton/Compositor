import Foundation
import Security

/// Somewhere to keep an API key that is not a preferences file.
nonisolated protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Nil or empty removes it.
    func setSecret(_ secret: String?, for account: String) throws
}

nonisolated enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The key could not be saved to your keychain. \((SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status).")"
        }
    }
}

/// The login keychain, as a generic password under the app's name. A sandboxed app reaches its own items
/// there without an entitlement; the data-protection keychain would need an access group this app does not sign with.
nonisolated struct KeychainSecretStore: SecretStore {
    var service = (Bundle.main.bundleIdentifier ?? "Compositor") + ".generative"

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func secret(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String?, for account: String) throws {
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
            return
        }
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Compositor API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }
}

/// For tests, which must never reach the real keychain.
nonisolated final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    func secret(for account: String) -> String? { lock.withLock { secrets[account] } }
    func setSecret(_ secret: String?, for account: String) throws {
        lock.withLock { secrets[account] = secret?.isEmpty == false ? secret : nil }
    }
}
