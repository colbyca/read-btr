import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
struct BTRMenuViewModelTests {
    /// Canned-response `AIProvider` — records every prompt it was asked to
    /// answer, so tests can assert whether (and what) it was called with,
    /// without a real network call.
    final class MockAIProvider: AIProvider, @unchecked Sendable {
        var textToReturn = ""
        var errorToThrow: Error?
        private(set) var promptsReceived: [(prompt: String, schema: AIResponseSchema?)] = []

        func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String {
            promptsReceived.append((prompt, responseSchema))
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }
    }

    /// Real `Book`/`Publication` via the existing fixture pipeline, plus a
    /// real word-segment locator midway through the first real chapter —
    /// mirrors `BTRContextWindowTests`' setup, since the pipeline under
    /// test is built directly on top of that same context-resolution chain.
    /// A named struct rather than a tuple — five members is past the point
    /// a tuple stays readable at each call site.
    @MainActor
    struct Fixture {
        let book: Book
        let publication: Publication
        let anchorLocator: Locator
        let context: ModelContext
        let cleanup: () -> Void

        func makeViewModel(provider: AIProvider?, anchorLocator: Locator? = nil) -> BTRMenuViewModel {
            BTRMenuViewModel(
                book: book, publication: publication, anchorLocator: anchorLocator ?? self.anchorLocator,
                provider: provider, modelContext: context)
        }
    }

    private static func makeFixture() async throws -> Fixture {
        let (storage, cleanup) = try RSVPViewModelTests.makeTempStorage()
        let context = try RSVPViewModelTests.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
        try context.save()

        let fileURL = try storage.absoluteURL(forRelativePath: book.relativeFilePath)
        let publication = try await PublicationLoader().open(fileURL: fileURL)

        let chapterHref = publication.readingOrder[1].url().string
        let stream = try #require(await WordStream.build(for: chapterHref, in: publication))
        try #require(stream.words.count > 50)
        let anchorLocator = stream.words[50].locator

        return Fixture(
            book: book, publication: publication, anchorLocator: anchorLocator, context: context, cleanup: cleanup)
    }

    // MARK: - Preview pane

    @Test func preparePreviewBuildsANavigatorHostAtTheAnchorLocator() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        #expect(viewModel.previewNavigatorHost == nil)

        viewModel.preparePreview()
        #expect(viewModel.previewNavigatorHost != nil)
    }

    @Test func preparePreviewIsIdempotent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        viewModel.preparePreview()
        let first = viewModel.previewNavigatorHost
        viewModel.preparePreview()

        #expect(viewModel.previewNavigatorHost === first)
    }

    // MARK: - Step 1: entity extraction

    @Test func loadEntitiesPopulatesChipsFromProviderResponse() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"""
            {"entities":[{"name":"Alice","kind":"character"},{"name":"Wonderland","kind":"location"}]}
            """#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.loadEntities()

        guard case .result(let entities) = viewModel.entitiesState else {
            Issue.record("expected .result, got \(viewModel.entitiesState)")
            return
        }
        #expect(
            entities == [
                ExtractedEntity(name: "Alice", kind: .character),
                ExtractedEntity(name: "Wonderland", kind: .location),
            ])
        #expect(provider.promptsReceived.count == 1)
        if case .json = provider.promptsReceived.first?.schema {
            // expected — entity extraction requests structured output.
        } else {
            Issue.record("expected a .json response schema for entity extraction")
        }
    }

    @Test func loadEntitiesFailsGracefullyWithoutAProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        await viewModel.loadEntities()

        guard case .failed = viewModel.entitiesState else {
            Issue.record("expected .failed, got \(viewModel.entitiesState)")
            return
        }
    }

    @Test func loadEntitiesOnlyCallsTheProviderOnce() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"{"entities":[]}"#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.loadEntities()
        await viewModel.loadEntities()

        #expect(provider.promptsReceived.count == 1)
    }

    // MARK: - Step 2: entity summary

    @Test func selectEntityUsesCachedProfileWithoutCallingProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let existing = EntityProfile(
            displayName: "Alice", kind: .character, summary: "Cached summary.", firstMentionLocatorJSON: "",
            book: fixture.book)
        fixture.context.insert(existing)
        try fixture.context.save()

        let provider = MockAIProvider()
        provider.textToReturn = "Should never be returned."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "alice", kind: .character))

        #expect(viewModel.selectedOptionResult == .result("Cached summary."))
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func selectEntitySavesANewProfileWhenNotCached() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.book.entityProfiles.isEmpty)

        let provider = MockAIProvider()
        provider.textToReturn = "Alice is the curious protagonist."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "Alice", kind: .character))

        #expect(viewModel.selectedOptionResult == .result("Alice is the curious protagonist."))
        #expect(provider.promptsReceived.count == 1)
        #expect(fixture.book.entityProfiles.count == 1)
        #expect(fixture.book.entityProfiles.first?.canonicalName == "alice")
        #expect(fixture.book.entityProfiles.first?.summary == "Alice is the curious protagonist.")
    }

    @Test func selectEntityFailsWhenNoMentionsFound() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "Zzyzxqplorp", kind: .character))

        guard case .failed = viewModel.selectedOptionResult else {
            Issue.record("expected .failed, got \(viewModel.selectedOptionResult)")
            return
        }
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.entityProfiles.isEmpty)
    }

    // MARK: - "Summarize since start of chapter"

    @Test func summarizeChapterGeneratesAndCachesANewSummary() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.book.chapterSummaries.isEmpty)

        let provider = MockAIProvider()
        provider.textToReturn = "Alice fell down a rabbit hole."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Alice fell down a rabbit hole."))
        #expect(provider.promptsReceived.count == 1)
        #expect(fixture.book.chapterSummaries.count == 1)
        #expect(fixture.book.chapterSummaries.first?.chapterHref == fixture.anchorLocator.href.string)
    }

    @Test func summarizeChapterReusesAFreshCacheWithoutCallingProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        // Pin the anchor's own progression explicitly rather than trusting
        // whatever progression a real word-segment locator happens to
        // carry natively — `isStale` only ever compares these two
        // progression values against each other, so the test controls both
        // sides directly.
        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        // Covers *past* the anchor's own progression — not stale.
        let coveringLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 1.0) })
        let cached = ChapterSummary(
            chapterHref: fixture.anchorLocator.href.string, content: "Cached chapter summary.",
            sourceEndLocatorJSON: try coveringLocator.jsonString(), book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Cached chapter summary."))
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.chapterSummaries.count == 1)
    }

    @Test func summarizeChapterRegeneratesAndOverwritesAStaleCache() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        // Covers *before* the anchor's own progression — stale, since the
        // reader has read further into the chapter since it was made.
        let staleLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.0) })
        let cached = ChapterSummary(
            chapterHref: fixture.anchorLocator.href.string, content: "Old summary.",
            sourceEndLocatorJSON: try staleLocator.jsonString(), book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        provider.textToReturn = "Fresh summary."
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Fresh summary."))
        #expect(provider.promptsReceived.count == 1)
        // Overwrote the existing row rather than creating a second one.
        #expect(fixture.book.chapterSummaries.count == 1)
        #expect(fixture.book.chapterSummaries.first?.content == "Fresh summary.")
    }
}
