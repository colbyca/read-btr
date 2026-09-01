import Foundation

/// Turns global config into a usable `AIProvider`, or `nil` if AI features
/// shouldn't run at all — the one place that check happens for real call
/// sites, mirroring `AppSettings.aiProviderIsUsable`'s "provider selected
/// and a Keychain key exists for it" rule (design-roadmap.md §2.6) rather
/// than re-deriving it ad hoc. Every BTR call site goes through this
/// instead of constructing `GeminiProvider` directly, so adding a second
/// provider is one new `case` here, nothing else.
enum AIProviderFactory {
    static func makeProvider(settings: AppSettings, keyStore: AIKeyStore) -> AIProvider? {
        guard let providerKind = settings.aiProvider, let key = keyStore.key(for: providerKind), !key.isEmpty else {
            return nil
        }
        switch providerKind {
        case .gemini:
            return GeminiProvider(apiKey: key)
        }
    }
}
