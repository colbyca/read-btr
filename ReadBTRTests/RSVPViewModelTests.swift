import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing
@testable import ReadBTR

@MainActor
struct RSVPViewModelTests {
    static func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// A throwaway temp directory per test, mirroring `BookImporterTests`.
    static func makeTempStorage() throws -> (storage: BookFileStorage, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RSVPViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = BookFileStorage(baseDirectoryOverride: tempDir)
        return (storage, { try? FileManager.default.removeItem(at: tempDir) })
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/alice.epub")
    }

    /// Imports the real fixture through the real pipeline, so these tests
    /// exercise RSVPViewModel exactly as it'll actually be used, not against
    /// a hand-built `Book`.
    static func makeLoadedViewModel() async throws -> (viewModel: RSVPViewModel, context: ModelContext, cleanup: () -> Void) {
        let (storage, cleanup) = try makeTempStorage()
        let context = try makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: fixtureURL, into: context)
        try context.save()

        let viewModel = RSVPViewModel(book: book, modelContext: context, fileStorage: storage)
        await viewModel.load()
        return (viewModel, context, cleanup)
    }

    @Test func loadResolvesToReadyWithAFirstWord() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        #expect(viewModel.loadState == .ready)
        #expect(viewModel.currentIndex == 0)

        // alice.epub's actual first reading-order resource ("wrap0000.html")
        // is a cover-image wrapper with no extractable text — this asserts
        // `load()` (via Book.currentRSVPIndex) skipped past it to land on
        // real content, not on an unusable empty word stream.
        #expect(viewModel.currentStream?.resourceHref != "OEBPS/wrap0000.html")
        #expect(viewModel.currentWord != nil)
    }

    @Test func stepForwardAdvancesWithinTheSameChapter() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let startingHref = viewModel.currentStream?.resourceHref
        await viewModel.step(by: 3)

        #expect(viewModel.currentIndex == 3)
        #expect(viewModel.currentStream?.resourceHref == startingHref)
    }

    @Test func stepBackwardFromTheStartOfTheBookClampsAtZero() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let startingHref = viewModel.currentStream?.resourceHref
        await viewModel.step(by: -1)

        #expect(viewModel.currentIndex == 0)
        #expect(viewModel.currentStream?.resourceHref == startingHref)
    }

    @Test func steppingPastTheEndOfAChapterCrossesIntoTheNextResource() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let firstHref = try #require(viewModel.currentStream?.resourceHref)
        let firstChapterWordCount = try #require(viewModel.currentStream?.words.count)

        // Step past the end of the first resource entirely.
        await viewModel.step(by: firstChapterWordCount + 2)

        let newHref = viewModel.currentStream?.resourceHref
        #expect(newHref != nil)
        #expect(newHref != firstHref, "expected stepping past the chapter's word count to land in a different resource")
        #expect(viewModel.currentIndex >= 0)
        #expect(viewModel.currentStream?.words.indices.contains(viewModel.currentIndex) == true)
    }

    @Test func selectChapterJumpsToThatChaptersStart() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let publication = try #require(viewModel.publication)
        let targetLink = publication.readingOrder[1]
        let targetHref = targetLink.url().string
        let targetLocator = try #require(await publication.locate(targetLink))

        await viewModel.selectChapter(targetLocator)

        #expect(viewModel.currentStream?.resourceHref == targetHref)
    }

    @Test func steppingPersistsPositionOnTheBook() async throws {
        let (viewModel, context, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let originalPosition = viewModel.book.position
        await viewModel.step(by: 5)

        #expect(viewModel.book.position.locatorJSON != originalPosition.locatorJSON)
        #expect(try context.fetch(FetchDescriptor<Book>()).first?.position.locatorJSON == viewModel.book.position.locatorJSON)
    }

    @Test func playSetsIsPlayingAndHidesToolbarPauseRevertsIt() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        viewModel.isShowingToolbar = true
        viewModel.play()
        #expect(viewModel.isPlaying == true)
        #expect(viewModel.isShowingToolbar == false)

        viewModel.pause()
        #expect(viewModel.isPlaying == false)
    }

    @Test func showToolbarPausesEvenIfAlreadyPaused() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        #expect(viewModel.isPlaying == false)
        viewModel.showToolbar()

        #expect(viewModel.isPlaying == false)
        #expect(viewModel.isShowingToolbar == true)
    }

    @Test func togglePlayPauseFlipsState() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        viewModel.togglePlayPause()
        #expect(viewModel.isPlaying == true)

        viewModel.togglePlayPause()
        #expect(viewModel.isPlaying == false)
    }
}

// MARK: - Save Quote

extension RSVPViewModelTests {
    @Test func saveQuoteStoresTheSentenceAroundTheCurrentWord() async throws {
        let (viewModel, context, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        await viewModel.step(by: 5)
        let currentWord = try #require(viewModel.currentWord)
        viewModel.showBTRTooltip()

        viewModel.saveQuote()

        let quotes = try context.fetch(FetchDescriptor<SavedQuote>())
        #expect(quotes.count == 1)
        #expect(quotes.first?.text.contains(currentWord) == true)
        #expect(quotes.first?.book === viewModel.book)
        #expect(viewModel.isShowingBTRTooltip == false)
        #expect(viewModel.quoteSavedConfirmationID != nil)
    }
}
