import Foundation
import Observation
import SwiftData

/// Drives `ConfigurationView` (design-roadmap.md §6.2). One view model
/// backs both entry modes: `book == nil` edits `AppSettings` (the global
/// defaults, reached from Home's settings icon); `book != nil` edits that
/// book's overrides (reached from a reading mode's own toolbar settings
/// icon), reading/writing through `Book.effectiveTheme`/
/// `effectiveReaderSettings`/`isAIFeatureEnabled` so the displayed values
/// are always the *effective* ones — inherited from global unless this
/// book has its own override.
///
/// Theme and reader settings are category-level overrides (design-roadmap.md
/// §2.5/§10): the first per-book edit in either group clones the *whole*
/// current effective value, then mutates the clone in place — never a
/// sparse per-field diff. AI feature flags are the opposite: sparse and
/// per-key, since `BookSettingsOverride.aiFeatureFlagOverrides` is designed
/// to only ever hold the keys a book actually overrides.
@MainActor
@Observable
final class ConfigurationViewModel {
    let book: Book?
    private(set) var appSettings: AppSettings

    private let modelContext: ModelContext

    var isPerBook: Bool { book != nil }

    init(book: Book?, modelContext: ModelContext) {
        self.book = book
        self.modelContext = modelContext
        appSettings = AppSettingsStore.current(in: modelContext)
    }

    // MARK: - Theme

    var theme: ReaderTheme {
        book?.effectiveTheme(appSettings) ?? appSettings.defaultTheme
    }

    var isThemeOverridden: Bool { book?.themeOverride != nil }

    func updateTheme(_ transform: (inout ReaderTheme) -> Void) {
        if let book {
            var theme = book.effectiveTheme(appSettings)
            transform(&theme)
            book.themeOverride = theme
        } else {
            var theme = appSettings.defaultTheme
            transform(&theme)
            appSettings.defaultTheme = theme
        }
        save()
    }

    func resetTheme() {
        book?.themeOverride = nil
        save()
    }

    // MARK: - Reader settings (RSVP / Guided Reading / Normal, together)

    var readerSettings: ReaderSettings {
        book?.effectiveReaderSettings(appSettings) ?? appSettings.defaultReaderSettings
    }

    var isReaderSettingsOverridden: Bool { book?.settingsOverride?.readerSettings != nil }

    func updateReaderSettings(_ transform: (inout ReaderSettings) -> Void) {
        if let book {
            var settings = book.effectiveReaderSettings(appSettings)
            transform(&settings)
            var override = book.settingsOverride ?? BookSettingsOverride()
            override.readerSettings = settings
            book.settingsOverride = override
        } else {
            var settings = appSettings.defaultReaderSettings
            transform(&settings)
            appSettings.defaultReaderSettings = settings
        }
        save()
    }

    func resetReaderSettings() {
        book?.settingsOverride?.readerSettings = nil
        save()
    }

    // MARK: - AI: global-only (provider, key, master toggle)

    var aiFeaturesMasterToggle: Bool {
        get { appSettings.aiFeaturesMasterToggle }
        set {
            appSettings.aiFeaturesMasterToggle = newValue
            save()
        }
    }

    var aiProvider: AIProviderKind? {
        get { appSettings.aiProvider }
        set {
            appSettings.aiProvider = newValue
            save()
        }
    }

    var aiProviderIsUsable: Bool { appSettings.aiProviderIsUsable }

    func apiKey(for provider: AIProviderKind) -> String {
        AppSettings.keyStore.key(for: provider) ?? ""
    }

    func setAPIKey(_ key: String, for provider: AIProviderKind) {
        AppSettings.keyStore.setKey(key.isEmpty ? nil : key, for: provider)
    }

    // MARK: - AI: per-feature (global default, sparse per-book override)

    func isAIFeatureEnabled(_ key: AIFeatureKey) -> Bool {
        if let book {
            return book.isAIFeatureEnabled(key, appSettings)
        }
        return appSettings.aiFeatureFlag(for: key)?.isEnabled ?? false
    }

    func isAIFeatureOverridden(_ key: AIFeatureKey) -> Bool {
        book?.settingsOverride?.aiFeatureFlagOverrides.contains { $0.key == key } ?? false
    }

    func setAIFeatureEnabled(_ key: AIFeatureKey, _ isEnabled: Bool) {
        if let book {
            var override = book.settingsOverride ?? BookSettingsOverride()
            override.aiFeatureFlagOverrides.removeAll { $0.key == key }
            override.aiFeatureFlagOverrides.append(AIFeatureFlag(key: key, isEnabled: isEnabled))
            book.settingsOverride = override
        } else {
            if let index = appSettings.aiFeatureFlags.firstIndex(where: { $0.key == key }) {
                appSettings.aiFeatureFlags[index].isEnabled = isEnabled
            } else {
                appSettings.aiFeatureFlags.append(AIFeatureFlag(key: key, isEnabled: isEnabled))
            }
        }
        save()
    }

    func resetAIFeatureOverride(_ key: AIFeatureKey) {
        book?.settingsOverride?.aiFeatureFlagOverrides.removeAll { $0.key == key }
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}
