import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing
import UIKit

@testable import ReadBTR

@MainActor
struct GuidedReadingViewModelTests {
    /// Imports the real fixture through the real pipeline, so these tests
    /// exercise GuidedReadingViewModel exactly as it'll actually be used —
    /// mirrors RSVPViewModelTests.makeLoadedViewModel.
    ///
    /// `load()` deliberately leaves `loadState == .loading` until the
    /// navigator's view has a real, non-zero size (line rects are
    /// meaningless before that, dev.md §4.3) — in the real app that
    /// happens once SwiftUI mounts `GuidedReadingNavigatorRepresentable`.
    /// A bare unit test never runs SwiftUI, so this stands a real
    /// `UIWindow` in for it and waits for `loadState` to settle exactly
    /// the way the app's own `onViewReady` → `finishLoadingOnceViewIsReady`
    /// chain does.
    static func makeLoadedViewModel() async throws -> (
        viewModel: GuidedReadingViewModel, context: ModelContext, cleanup: () -> Void
    ) {
        let (storage, cleanup) = try RSVPViewModelTests.makeTempStorage()
        let context = try RSVPViewModelTests.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
        try context.save()

        let viewModel = GuidedReadingViewModel(book: book, modelContext: context, fileStorage: storage)
        await viewModel.load()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if let host = viewModel.navigatorHost {
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }
        await Self.waitUntilSettled(viewModel)

        // Keep the window alive for the caller's use of the view model —
        // `cleanup()` is the one guaranteed retention point every test
        // already `defer`s to.
        let originalCleanup = cleanup
        return (
            viewModel, context,
            {
                _ = window
                originalCleanup()
            }
        )
    }

    /// Polls rather than trusting a fixed delay, mirroring
    /// `GuidedReadingViewModel.awaitLinesReady`'s own reasoning: there's no
    /// push-based "layout finished" signal to `await` here.
    static func waitUntilSettled(_ viewModel: GuidedReadingViewModel, maxAttempts: Int = 50) async {
        for _ in 0..<maxAttempts {
            if viewModel.loadState != .loading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Regression guard for a bug found via manual/UI-test diagnosis:
    /// ReadiumCSS applies its own broad `!important`-flagged background
    /// reset to defeat publisher styles, which was *also* silently
    /// discarding a plain (non-`!important`) inline `background-color` on
    /// our own injected highlight element — `elStyle` (what we told the
    /// DOM to set) kept reporting the color while `getComputedStyle`
    /// (what actually paints) reported fully transparent, so the highlight
    /// existed with correct geometry but was invisible.
    /// `GuidedReadingHighlighter.js`'s `setImportant` helper is the fix;
    /// this checks the browser's *actual rendered* color, not just the
    /// inline style string, which is exactly the distinction that hid the
    /// bug from a naive check.
    @Test func highlightLineActuallyPaintsANonTransparentBackground() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let snapshotJSON = try #require(await viewModel.navigatorHost?.debugHighlightSnapshot())
        let snapshotData = try #require(snapshotJSON.data(using: .utf8))
        let snapshot = try #require(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])

        #expect(snapshot["hasElement"] as? Bool == true)

        let elStyle = try #require(snapshot["elStyle"] as? [String: Any])
        let elComputed = try #require(snapshot["elComputed"] as? [String: Any])

        #expect(elComputed["backgroundColor"] as? String == elStyle["backgroundColor"] as? String)
        #expect(elComputed["backgroundColor"] as? String != "rgba(0, 0, 0, 0)")
    }

    /// Regression guard for a bug found from real cross-mode use: opening
    /// the same book in RSVP vs. Guided Reading landed at two visibly
    /// different spots. Root cause was `handleLocationChange` persisting
    /// the navigator's raw scroll-derived `Locator` verbatim, but
    /// auto-scroll deliberately leaves the highlighted line ~35% down the
    /// viewport (`GuidedReadingHighlighter.js`'s `ANCHOR_FRACTION`) — so the
    /// saved progression systematically undershot the actual reading
    /// position by about a third of a screen's worth of text. This checks
    /// the corrected value directly: persisted progression should match
    /// `(currentLineIndex + 0.5) / lineCount`, not whatever the raw scroll
    /// offset happened to be.
    @Test func persistedPositionProgressionMatchesTheHighlightedLine() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let expectedProgression = (Double(viewModel.currentLineIndex) + 0.5) / Double(viewModel.lineCount)
        let locator = try Locator(jsonString: viewModel.book.position.locatorJSON)
        let actualProgression = try #require(locator.locations.progression)

        #expect(abs(actualProgression - expectedProgression) < 0.0001)
    }

    /// The end-to-end version of the same regression: after Guided Reading
    /// has actually advanced a few lines (not just the trivial "both modes
    /// agree on the very beginning of the book" case), RSVP resolving that
    /// same saved position should land somewhere in the neighborhood of
    /// what Guided Reading was actually showing — not a third of a screen
    /// earlier.
    @Test func crossModePositionRoughlyMatchesRSVPAfterAdvancing() async throws {
        let (storage, cleanup) = try RSVPViewModelTests.makeTempStorage()
        defer { cleanup() }
        let context = try RSVPViewModelTests.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
        try context.save()

        let guidedViewModel = GuidedReadingViewModel(book: book, modelContext: context, fileStorage: storage)
        await guidedViewModel.load()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if let host = guidedViewModel.navigatorHost {
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }
        await Self.waitUntilSettled(guidedViewModel)

        let initialIndex = guidedViewModel.currentLineIndex
        guidedViewModel.play()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        guidedViewModel.pause()
        let advancedIndex = guidedViewModel.currentLineIndex
        let lineCount = guidedViewModel.lineCount
        try #require(advancedIndex != initialIndex, "test needs playback to have actually advanced past the first line")

        // Resolve the exact same saved position through RSVP's own,
        // independent pipeline, then compare *where in the word stream*
        // each mode landed — not the literal word/text, since alice.epub's
        // decorative title-page formatting can split single letters into
        // their own "lines," which would make a text-based comparison
        // flaky regardless of whether the position fix is correct.
        let resourceHref = try #require(book.currentLocator?.href.string)
        let fileURL = try storage.absoluteURL(forRelativePath: book.relativeFilePath)
        let publication = try await PublicationLoader().open(fileURL: fileURL)
        let wordStream = try #require(await WordStream.build(for: resourceHref, in: publication))
        let expectedIndex = Int((Double(advancedIndex) + 0.5) / Double(lineCount) * Double(wordStream.words.count))

        let rsvpViewModel = RSVPViewModel(book: book, modelContext: context, fileStorage: storage)
        await rsvpViewModel.load()
        let actualIndex = rsvpViewModel.currentIndex

        let failureMessage = """
            RSVP resolved word index \(actualIndex), expected near \(expectedIndex) \
            (Guided Reading was on line \(advancedIndex)/\(lineCount))
            """
        #expect(abs(actualIndex - expectedIndex) < 60, "\(failureMessage)")
    }

    @Test func loadResolvesToReadyWithARealLineAndNavigator() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        #expect(viewModel.loadState == .ready)
        #expect(viewModel.navigatorHost != nil)
        #expect(viewModel.lineCount > 0)
        #expect(viewModel.currentLineIndex >= 0)

        // alice.epub's actual first reading-order resource is a
        // cover-image wrapper with no extractable text — asserts `load()`
        // skipped past it to land on a resource with real, renderable lines.
        let firstLine = await viewModel.navigatorHost?.lineText(at: viewModel.currentLineIndex)
        #expect(firstLine != nil)
        #expect(firstLine?.isEmpty == false)
    }

    @Test func selectChapterJumpsToThatChaptersStartAndRebuildsLines() async throws {
        let (viewModel, _, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let publication = try #require(viewModel.publication)
        let targetLink = publication.readingOrder[1]
        let targetLocator = try #require(await publication.locate(targetLink))

        await viewModel.selectChapter(targetLocator)

        #expect(viewModel.lineCount > 0)
        #expect(viewModel.book.position.resourceHref == targetLink.url().string)
    }

    @Test func selectChapterPersistsPositionOnTheBook() async throws {
        let (viewModel, context, cleanup) = try await Self.makeLoadedViewModel()
        defer { cleanup() }

        let publication = try #require(viewModel.publication)
        // `readingOrder[1]` is the same resource `load()` itself already
        // resolves to (the first non-empty one, past alice.epub's
        // text-less cover wrapper) — index 3 guarantees an actually
        // different resource, so "position changed" is a meaningful check
        // rather than comparing a resource against itself.
        let targetLocator = try #require(await publication.locate(publication.readingOrder[3]))
        let originalPosition = viewModel.book.position

        await viewModel.selectChapter(targetLocator)

        #expect(viewModel.book.position.locatorJSON != originalPosition.locatorJSON)
        #expect(
            try context.fetch(FetchDescriptor<Book>()).first?.position.locatorJSON
                == viewModel.book.position.locatorJSON)
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
