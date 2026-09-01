import Foundation
import SwiftData

/// Global configuration. SwiftData has no native singleton concept — exactly
/// one row of this model should ever exist, fetched-or-created via
/// `AppSettingsStore.current(in:)` (Persistence/AppSettingsStore.swift).
/// Every screen reads/writes through that helper, never queries
/// `AppSettings` directly (design-roadmap.md §2.6).
@Model
final class AppSettings {
    var defaultTheme: ReaderTheme
    var defaultReaderSettings: ReaderSettings
    var aiFeaturesMasterToggle: Bool
    var aiFeatureFlags: [AIFeatureFlag]
    var aiProvider: AIProviderKind?
    var supabaseSyncEnabled: Bool

    init(
        defaultTheme: ReaderTheme = .default,
        defaultReaderSettings: ReaderSettings = .default,
        aiFeaturesMasterToggle: Bool = false,
        aiFeatureFlags: [AIFeatureFlag] = .allDisabledByDefault,
        aiProvider: AIProviderKind? = nil,
        supabaseSyncEnabled: Bool = false
    ) {
        self.defaultTheme = defaultTheme
        self.defaultReaderSettings = defaultReaderSettings
        self.aiFeaturesMasterToggle = aiFeaturesMasterToggle
        self.aiFeatureFlags = aiFeatureFlags
        self.aiProvider = aiProvider
        self.supabaseSyncEnabled = supabaseSyncEnabled
    }
}

extension AppSettings {
    /// "If a provider or key is not given, AI features should be disabled"
    /// (design-roadmap.md §6.2) — enforced here, in one place, rather than
    /// re-checked ad hoc at every AI call site.
    var aiProviderIsUsable: Bool {
        guard let aiProvider else { return false }
        return AppSettings.keyStore.hasKey(for: aiProvider)
    }

    func aiFeatureFlag(for key: AIFeatureKey) -> AIFeatureFlag? {
        aiFeatureFlags.first { $0.key == key }
    }

    /// Swappable for tests; defaults to the real Keychain-backed store.
    /// `nonisolated(unsafe)`: Keychain Services calls are themselves
    /// thread-safe, and this is only ever reassigned once, at test setup —
    /// never mutated concurrently during normal app operation.
    nonisolated(unsafe) static var keyStore: AIKeyStore = KeychainAIKeyStore()
}
