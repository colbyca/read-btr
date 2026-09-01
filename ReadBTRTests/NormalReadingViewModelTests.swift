import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
struct NormalReadingViewModelTests {
    /// Imports the real fixture through the real pipeline — mirrors
    /// RSVPViewModelTests/GuidedReadingViewModelTests.makeLoadedViewModel.
    /// Unlike Guided Reading, `load()` doesn't depend on the navigator's
    /// view ever being laid out (no custom line computation), so this
    /// doesn't need the `UIWindow`-attachment dance
    /// `GuidedReadingViewModelTests` needs.
    static func makeLoadedViewModel() async throws -> (
        viewModel: NormalReadingViewModel, context: ModelContext, cleanup: () -> Void
    ) {
        let (storage, cleanup) = try RSVPViewModelTests.makeTempStorage()
        let context = try RSVPViewModelTests.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
        try context.save()

        let viewModel = NormalReadingViewModel(book: book, modelContext: context, fileStorage: storage)
        await viewModel.load()
        return (viewModel, context, cleanup)
    }

    @Test func loadResolvesToReadyWithANavigator() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        #expect(viewModel.loadState == .ready)
        #expect(viewModel.navigatorHost != nil)
        #expect(viewModel.publication != nil)
    }

    @Test func selectChapterJumpsAndPersistsPosition() async throws {
        let (viewModel, context, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let publication = try #require(viewModel.publication)
        let targetLink = publication.readingOrder[1]
        let targetLocator = try #require(await publication.locate(targetLink))
        let originalPosition = viewModel.book.position

        await viewModel.selectChapter(targetLocator)

        #expect(viewModel.book.position.resourceHref == targetLink.url().string)
        #expect(viewModel.book.position.locatorJSON != originalPosition.locatorJSON)
        #expect(
            try context.fetch(FetchDescriptor<Book>()).first?.position.locatorJSON
                == viewModel.book.position.locatorJSON)
    }

    @Test func selectChapterHidesTheToolbar() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        viewModel.isShowingToolbar = true
        let publication = try #require(viewModel.publication)
        let targetLocator = try #require(await publication.locate(publication.readingOrder[1]))

        await viewModel.selectChapter(targetLocator)

        #expect(viewModel.isShowingToolbar == false)
    }
}
