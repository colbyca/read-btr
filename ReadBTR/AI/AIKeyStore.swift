import Foundation
import Security

/// Storage for user-supplied AI provider API keys. Deliberately never
/// SwiftData — keys live in the Keychain only, never in UserDefaults, plain
/// files, or the app's model store (dev.md §3, design-roadmap.md §2.7).
protocol AIKeyStore {
    func key(for provider: AIProviderKind) -> String?
    func setKey(_ key: String?, for provider: AIProviderKind)
    func hasKey(for provider: AIProviderKind) -> Bool
}

extension AIKeyStore {
    func hasKey(for provider: AIProviderKind) -> Bool {
        guard let key = key(for: provider) else { return false }
        return !key.isEmpty
    }
}

/// Keychain Services-backed implementation. One generic-password item per
/// provider, keyed by `AIProviderKind.rawValue`.
final class KeychainAIKeyStore: AIKeyStore {
    private let service: String

    init(service: String = "com.colbycarter.readbtr.ai-provider-keys") {
        self.service = service
    }

    func key(for provider: AIProviderKind) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String?, for provider: AIProviderKind) {
        let query = baseQuery(for: provider)

        guard let key, !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(key.utf8)

        // Try updating an existing item first; add a new one if none exists.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    private func baseQuery(for provider: AIProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
