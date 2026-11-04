import Foundation
@preconcurrency import ReadiumShared
import Testing

@testable import ReadBTR

// MARK: - WordStream.window(around:radius:), synthetic data

struct WordStreamWindowTests {
    @Test func windowAroundMiddleIndexIsSymmetric() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        let window = stream.window(around: 50, radius: 10)

        #expect(window.count == 21)
        #expect(window.first?.text == "word40")
        #expect(window.last?.text == "word60")
    }

    @Test func windowClampsAtTheStartOfTheStream() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        let window = stream.window(around: 2, radius: 10)

        // Shorter near the edge rather than reaching negative — the
        // resource-clamped simplification design-roadmap.md §10 calls out.
        #expect(window.first?.text == "word0")
        #expect(window.count == 13)
    }

    @Test func windowClampsAtTheEndOfTheStream() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        let window = stream.window(around: 97, radius: 10)

        #expect(window.last?.text == "word99")
        // Indices 87...99 inclusive — 10 words short (radius) plus itself.
        #expect(window.count == 13)
    }

    @Test func windowForOutOfBoundsIndexIsEmpty() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        #expect(stream.window(around: 500, radius: 10).isEmpty)
    }
}

// MARK: - BTRBookTextExtractor, against the real fixture

@MainActor
struct BTRBookTextExtractorTests {
    @Test func wholeBookAndUpToAPositionDifferAndKeepChapterLabels() async throws {
        let fixture = try await BTRChatViewModelTests.makeFixture()
        defer { fixture.cleanup() }

        let whole = await BTRBookTextExtractor.passages(of: fixture.publication, upTo: nil)
        let soFar = await BTRBookTextExtractor.passages(of: fixture.publication, upTo: fixture.anchorLocator)

        #expect(!soFar.isEmpty)
        #expect(soFar.count < whole.count)
        // Up-to-position text is a prefix of the whole book's text.
        #expect(Array(whole.prefix(soFar.count - 1)) == Array(soFar.dropLast()))
        #expect(whole.allSatisfy { !$0.chapter.isEmpty })
        #expect(Set(whole.map(\.chapter)).count > 1)
    }
}

// MARK: - BTRChapterTextExtractor, against the real fixture

@MainActor
struct BTRChapterTextExtractorTests {
    @Test func extractsTextUpToAGivenProgression() async throws {
        let publication = try await WordStreamTests.openFixture()
        let link = publication.readingOrder[1]
        let startLocator = try #require(await publication.locate(link))

        let partial = startLocator.copy(locations: { $0 = Locator.Locations(progression: 0.2) })
        let fuller = startLocator.copy(locations: { $0 = Locator.Locations(progression: 0.8) })

        let partialText = try #require(await BTRChapterTextExtractor.extractText(upTo: partial, in: publication))
        let fullerText = try #require(await BTRChapterTextExtractor.extractText(upTo: fuller, in: publication))

        #expect(!partialText.isEmpty)
        // Reading further into the same chapter should only ever accumulate
        // more text, never less.
        #expect(fullerText.count >= partialText.count)
    }

    @Test func returnsNilForAnUnknownHref() async throws {
        let publication = try await WordStreamTests.openFixture()
        let locator = try RSVPPositionResolverTests.makeLocator(progression: 0.5)
        let text = await BTRChapterTextExtractor.extractText(upTo: locator, in: publication)
        #expect(text == nil)
    }
}
