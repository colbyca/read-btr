import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing
@testable import ReadBTR

@MainActor
struct ModelsTests {
    /// Fresh in-memory SwiftData container per test — no state leaks
    /// between tests, no real disk I/O.
    static func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    static func makePosition(href: String = "chapter1.xhtml") -> BookPosition {
        BookPosition(
            locatorJSON: #"{"href":"\#(href)","type":"application/xhtml+xml"}"#,
            resourceHref: href,
            updatedAt: .now
        )
    }

    // MARK: - Book insert/fetch + relationships

    @Test func bookInsertsAndFetchesWithFields() throws {
        let context = try Self.makeContext()
        let book = Book(
            title: "Alice's Adventures in Wonderland",
            author: "Lewis Carroll",
            relativeFilePath: "Books/alice.epub",
            position: Self.makePosition()
        )
        context.insert(book)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Alice's Adventures in Wonderland")
        #expect(fetched.first?.format == .epub)
        #expect(fetched.first?.themeOverride == nil)
    }

    @Test func bookRelationshipsCascadeDeleteWithBook() throws {
        let context = try Self.makeContext()
        let book = Book(title: "Test Book", relativeFilePath: "Books/test.epub", position: Self.makePosition())
        context.insert(book)

        let summary = ChapterSummary(
            chapterHref: "chapter1.xhtml",
            content: "Things happened.",
            sourceEndLocatorJSON: Self.makePosition().locatorJSON,
            book: book
        )
        let entity = EntityProfile(
            displayName: "White Rabbit",
            kind: .character,
            summary: "A hurried rabbit.",
            firstMentionLocatorJSON: Self.makePosition().locatorJSON,
            book: book
        )
        let quote = SavedQuote(
            text: "Down the rabbit-hole.",
            startLocatorJSON: Self.makePosition().locatorJSON,
            endLocatorJSON: Self.makePosition().locatorJSON,
            book: book
        )
        context.insert(summary)
        context.insert(entity)
        context.insert(quote)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ChapterSummary>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EntityProfile>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SavedQuote>()).count == 1)

        context.delete(book)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ChapterSummary>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EntityProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SavedQuote>()).isEmpty)
    }

    // MARK: - EntityProfile dedup key

    @Test func entityProfileCanonicalizesDisplayNameForDedup() {
        let entity = EntityProfile(
            displayName: "  The White Rabbit  ",
            kind: .character,
            summary: "...",
            firstMentionLocatorJSON: "{}"
        )
        #expect(entity.canonicalName == "the white rabbit")
        #expect(entity.displayName == "  The White Rabbit  ")
    }

    // MARK: - AppSettingsStore singleton

    @Test func appSettingsStoreFetchesOrCreatesExactlyOneRow() throws {
        let context = try Self.makeContext()

        let first = AppSettingsStore.current(in: context)
        try context.save()
        let second = AppSettingsStore.current(in: context)

        #expect(first === second)
        #expect(try context.fetch(FetchDescriptor<AppSettings>()).count == 1)
    }

    // MARK: - Effective settings resolution

    @Test func effectiveReaderSettingsFallsBackToGlobalWhenNoOverride() {
        let global = AppSettings()
        let book = Book(title: "T", relativeFilePath: "Books/t.epub", position: Self.makePosition())

        #expect(book.effectiveReaderSettings(global) == global.defaultReaderSettings)
    }

    @Test func effectiveReaderSettingsUsesOverrideWhenPresent() {
        let global = AppSettings()
        var override = ReaderSettings.default
        override.rsvp.wordsPerMinute = 500

        let book = Book(
            title: "T",
            relativeFilePath: "Books/t.epub",
            position: Self.makePosition(),
            settingsOverride: BookSettingsOverride(readerSettings: override)
        )

        #expect(book.effectiveReaderSettings(global).rsvp.wordsPerMinute == 500)
        #expect(book.effectiveReaderSettings(global) != global.defaultReaderSettings)
    }

    @Test func effectiveThemeUsesBookOverrideOverGlobalDefault() {
        let global = AppSettings()
        var override = ReaderTheme.default
        override.backgroundColorHex = "#000000"

        let book = Book(
            title: "T",
            relativeFilePath: "Books/t.epub",
            position: Self.makePosition(),
            themeOverride: override
        )

        #expect(book.effectiveTheme(global).backgroundColorHex == "#000000")
    }

    // MARK: - AI feature gating

    struct FakeAIKeyStore: AIKeyStore {
        var keys: [AIProviderKind: String] = [:]
        func key(for provider: AIProviderKind) -> String? { keys[provider] }
        func setKey(_ key: String?, for provider: AIProviderKind) {}
    }

    @Test func aiFeatureDisabledWithoutProviderKey() {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = FakeAIKeyStore()

        let global = AppSettings(
            aiFeaturesMasterToggle: true,
            aiFeatureFlags: [AIFeatureFlag(key: .chapterSummary, isEnabled: true)],
            aiProvider: .gemini
        )
        let book = Book(title: "T", relativeFilePath: "Books/t.epub", position: Self.makePosition())

        #expect(book.isAIFeatureEnabled(.chapterSummary, global) == false)
    }

    @Test func aiFeatureDisabledWhenMasterToggleOff() {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = FakeAIKeyStore(keys: [.gemini: "test-key"])

        let global = AppSettings(
            aiFeaturesMasterToggle: false,
            aiFeatureFlags: [AIFeatureFlag(key: .chapterSummary, isEnabled: true)],
            aiProvider: .gemini
        )
        let book = Book(title: "T", relativeFilePath: "Books/t.epub", position: Self.makePosition())

        #expect(book.isAIFeatureEnabled(.chapterSummary, global) == false)
    }

    @Test func aiFeatureEnabledWhenProviderKeyedAndFlagOn() {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = FakeAIKeyStore(keys: [.gemini: "test-key"])

        let global = AppSettings(
            aiFeaturesMasterToggle: true,
            aiFeatureFlags: [AIFeatureFlag(key: .chapterSummary, isEnabled: true)],
            aiProvider: .gemini
        )
        let book = Book(title: "T", relativeFilePath: "Books/t.epub", position: Self.makePosition())

        #expect(book.isAIFeatureEnabled(.chapterSummary, global) == true)
    }

    @Test func perBookAIFeatureOverrideWinsOverGlobalFlag() {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = FakeAIKeyStore(keys: [.gemini: "test-key"])

        let global = AppSettings(
            aiFeaturesMasterToggle: true,
            aiFeatureFlags: [AIFeatureFlag(key: .chapterSummary, isEnabled: true)],
            aiProvider: .gemini
        )
        let book = Book(
            title: "T",
            relativeFilePath: "Books/t.epub",
            position: Self.makePosition(),
            settingsOverride: BookSettingsOverride(
                aiFeatureFlagOverrides: [AIFeatureFlag(key: .chapterSummary, isEnabled: false)]
            )
        )

        #expect(book.isAIFeatureEnabled(.chapterSummary, global) == false)
    }

    // MARK: - Position translation (design-roadmap.md §4.5)

    @Test func updatePositionFromLocatorRoundTripsThroughCurrentLocator() throws {
        let book = Book(title: "T", relativeFilePath: "Books/t.epub", position: Self.makePosition())
        let locator = try Locator(jsonString: #"{"href":"chapter2.xhtml","type":"application/xhtml+xml"}"#)

        book.updatePosition(from: locator)

        #expect(book.position.resourceHref == "chapter2.xhtml")
        #expect(book.currentLocator?.href == locator.href)
        #expect(book.currentLocator?.mediaType == locator.mediaType)
    }

    // MARK: - Keychain-backed key store

    @Test func keychainAIKeyStoreSetGetDeleteRoundTrips() {
        // Unique service name per test run so parallel/repeated test runs
        // never collide on the same Keychain item.
        let store = KeychainAIKeyStore(service: "com.colbycarter.readbtr.tests.\(UUID().uuidString)")

        #expect(store.hasKey(for: .gemini) == false)

        store.setKey("sk-test-123", for: .gemini)
        #expect(store.key(for: .gemini) == "sk-test-123")
        #expect(store.hasKey(for: .gemini) == true)

        store.setKey(nil, for: .gemini)
        #expect(store.key(for: .gemini) == nil)
        #expect(store.hasKey(for: .gemini) == false)
    }
}
