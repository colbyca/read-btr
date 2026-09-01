import Foundation
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
struct ConfigurationViewModelTests {
    static func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    static func makeBook(in context: ModelContext) -> Book {
        let book = Book(
            title: "Alice's Adventures in Wonderland",
            relativeFilePath: "Books/alice.epub",
            position: BookPosition(locatorJSON: "{}", resourceHref: "chapter1.xhtml", updatedAt: .now)
        )
        context.insert(book)
        return book
    }

    // MARK: - Global mode

    @Test func globalModeEditsAppSettingsDirectly() throws {
        let context = try Self.makeContext()
        let viewModel = ConfigurationViewModel(book: nil, modelContext: context)

        #expect(viewModel.isPerBook == false)

        viewModel.updateTheme { $0.backgroundColorHex = "#111111" }
        #expect(viewModel.appSettings.defaultTheme.backgroundColorHex == "#111111")
        #expect(viewModel.theme.backgroundColorHex == "#111111")

        viewModel.updateReaderSettings { $0.rsvp.wordsPerMinute = 450 }
        #expect(viewModel.appSettings.defaultReaderSettings.rsvp.wordsPerMinute == 450)
    }

    @Test func globalModePersistsAcrossFreshStoreLookup() throws {
        let context = try Self.makeContext()
        let viewModel = ConfigurationViewModel(book: nil, modelContext: context)

        viewModel.updateTheme { $0.fontSize = 24 }
        try context.save()

        let reloaded = AppSettingsStore.current(in: context)
        #expect(reloaded.defaultTheme.fontSize == 24)
    }

    // MARK: - Per-book mode: theme (category-level override)

    @Test func perBookThemeStartsUnoverridden() throws {
        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)

        #expect(viewModel.isPerBook == true)
        #expect(viewModel.isThemeOverridden == false)
        #expect(viewModel.theme == viewModel.appSettings.defaultTheme)
    }

    @Test func perBookThemeEditClonesEffectiveThemeThenOverridesOneField() throws {
        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)
        let originalFontSize = viewModel.appSettings.defaultTheme.fontSize

        viewModel.updateTheme { $0.backgroundColorHex = "#222222" }

        #expect(viewModel.isThemeOverridden == true)
        #expect(viewModel.theme.backgroundColorHex == "#222222")
        // Category-level clone: untouched fields carry over from the
        // effective (global) value, not reset to some other default.
        #expect(viewModel.theme.fontSize == originalFontSize)
        // The global default itself is untouched.
        #expect(viewModel.appSettings.defaultTheme.backgroundColorHex != "#222222")
    }

    @Test func perBookThemeResetFallsBackToGlobalDefault() throws {
        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)

        viewModel.updateTheme { $0.backgroundColorHex = "#222222" }
        #expect(viewModel.isThemeOverridden == true)

        viewModel.resetTheme()

        #expect(viewModel.isThemeOverridden == false)
        #expect(viewModel.theme.backgroundColorHex == viewModel.appSettings.defaultTheme.backgroundColorHex)
    }

    // MARK: - Per-book mode: reader settings (category-level, all three modes together)

    @Test func perBookReaderSettingsEditCoversAllThreeModesTogether() throws {
        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)

        viewModel.updateReaderSettings { $0.rsvp.wordsPerMinute = 600 }

        #expect(viewModel.isReaderSettingsOverridden == true)
        #expect(viewModel.readerSettings.rsvp.wordsPerMinute == 600)
        // Guided Reading/Normal settings came along in the same clone,
        // untouched — not reset to some other default (design-roadmap.md
        // §2.5/§10: category-level, not field-level).
        #expect(viewModel.readerSettings.guidedReading == viewModel.appSettings.defaultReaderSettings.guidedReading)
        #expect(viewModel.readerSettings.normalMode == viewModel.appSettings.defaultReaderSettings.normalMode)
    }

    @Test func perBookReaderSettingsResetFallsBackToGlobalDefault() throws {
        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)

        viewModel.updateReaderSettings { $0.rsvp.wordsPerMinute = 600 }
        viewModel.resetReaderSettings()

        #expect(viewModel.isReaderSettingsOverridden == false)
        #expect(
            viewModel.readerSettings.rsvp.wordsPerMinute
                == viewModel.appSettings.defaultReaderSettings.rsvp.wordsPerMinute)
    }

    // MARK: - AI: sparse, per-feature override

    @Test func perBookAIFeatureOverrideIsSparseNotCategoryLevel() throws {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)
        viewModel.appSettings.aiFeaturesMasterToggle = true
        viewModel.appSettings.aiProvider = .gemini
        viewModel.appSettings.aiFeatureFlags = [
            AIFeatureFlag(key: .chapterSummary, isEnabled: true),
            AIFeatureFlag(key: .entityExtraction, isEnabled: false)
        ]

        viewModel.setAIFeatureEnabled(.entityExtraction, true)

        #expect(viewModel.isAIFeatureOverridden(.entityExtraction) == true)
        #expect(viewModel.isAIFeatureEnabled(.entityExtraction) == true)
        // Only the touched key was overridden — chapterSummary still reads
        // straight from the global flag, no override recorded for it.
        #expect(viewModel.isAIFeatureOverridden(.chapterSummary) == false)
        #expect(viewModel.isAIFeatureEnabled(.chapterSummary) == true)
    }

    @Test func perBookAIFeatureResetRemovesOnlyThatKeysOverride() throws {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        let context = try Self.makeContext()
        let book = Self.makeBook(in: context)
        let viewModel = ConfigurationViewModel(book: book, modelContext: context)
        viewModel.appSettings.aiFeaturesMasterToggle = true
        viewModel.appSettings.aiProvider = .gemini

        viewModel.setAIFeatureEnabled(.entityExtraction, true)
        viewModel.setAIFeatureEnabled(.comprehensionCheck, true)
        viewModel.resetAIFeatureOverride(.entityExtraction)

        #expect(viewModel.isAIFeatureOverridden(.entityExtraction) == false)
        #expect(viewModel.isAIFeatureOverridden(.comprehensionCheck) == true)
    }

    @Test func globalAIFeatureToggleWritesAppSettingsFlagsArray() throws {
        let context = try Self.makeContext()
        let viewModel = ConfigurationViewModel(book: nil, modelContext: context)

        viewModel.setAIFeatureEnabled(.chapterSummary, true)

        #expect(viewModel.appSettings.aiFeatureFlag(for: .chapterSummary)?.isEnabled == true)
    }

    // MARK: - API key storage

    @Test func apiKeyRoundTripsThroughTheKeyStore() throws {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        // `ModelsTests.FakeAIKeyStore.setKey` is deliberately a no-op stub
        // (it only exists to feed preset keys into AI-gating tests) — this
        // needs a store that actually records writes, so it uses the real
        // Keychain-backed one, same as `ModelsTests.keychainAIKeyStoreSetGetDeleteRoundTrips`.
        AppSettings.keyStore = KeychainAIKeyStore(service: "com.colbycarter.readbtr.tests.\(UUID().uuidString)")

        let context = try Self.makeContext()
        let viewModel = ConfigurationViewModel(book: nil, modelContext: context)

        #expect(viewModel.apiKey(for: .gemini).isEmpty)

        viewModel.setAPIKey("sk-test-abc", for: .gemini)
        #expect(viewModel.apiKey(for: .gemini) == "sk-test-abc")

        viewModel.setAPIKey("", for: .gemini)
        #expect(viewModel.apiKey(for: .gemini).isEmpty)
    }
}
