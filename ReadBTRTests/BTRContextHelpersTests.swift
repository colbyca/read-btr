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

// MARK: - BTRContextWindow, against the real fixture

@MainActor
struct BTRContextWindowTests {
    @Test func snippetAroundALocatorContainsSurroundingWords() async throws {
        let publication = try await WordStreamTests.openFixture()
        let chapterHref = publication.readingOrder[1].url().string
        let stream = try #require(await WordStream.build(for: chapterHref, in: publication))
        try #require(stream.words.count > 50)

        // A real word-segment locator midway through the chapter — the same
        // shape `RSVPPositionResolver` refines against for a saved RSVP
        // position.
        let locator = stream.words[50].locator
        let cache = WordStreamCache()

        let snippet = try #require(
            await BTRContextWindow.snippet(around: locator, in: publication, cache: cache, radius: 20))

        #expect(!snippet.isEmpty)
        // ±20 words around index 50 should include the word at index 50
        // itself.
        #expect(snippet.contains(stream.words[50].text))
    }

    @Test func snippetReturnsNilForAnUnresolvableHref() async throws {
        let publication = try await WordStreamTests.openFixture()
        let locator = try RSVPPositionResolverTests.makeLocator(progression: 0.5)
        let cache = WordStreamCache()

        // `RSVPPositionResolverTests.makeLocator`'s href ("chapter1.xhtml")
        // isn't a real resource in alice.epub.
        let snippet = await BTRContextWindow.snippet(around: locator, in: publication, cache: cache, radius: 20)
        #expect(snippet == nil)
    }
}

// MARK: - BTREntityContextGatherer, against the real fixture

@MainActor
struct BTREntityContextGathererTests {
    @Test func gathersSnippetsMentioningAKnownName() async throws {
        let publication = try await WordStreamTests.openFixture()
        let chapterHref = publication.readingOrder[1].url().string

        let snippets = await BTREntityContextGatherer.gatherSnippets(
            forEntityNamed: "Alice", upThroughResourceHref: chapterHref, in: publication)

        #expect(!snippets.isEmpty)
        #expect(snippets.localizedCaseInsensitiveContains("Alice"))
    }

    @Test func returnsEmptyForANameThatNeverAppears() async throws {
        let publication = try await WordStreamTests.openFixture()
        let chapterHref = publication.readingOrder[1].url().string

        let snippets = await BTREntityContextGatherer.gatherSnippets(
            forEntityNamed: "Zzyzxqplorp", upThroughResourceHref: chapterHref, in: publication)

        #expect(snippets.isEmpty)
    }

    @Test func returnsEmptyForAnUnknownResourceHref() async throws {
        let publication = try await WordStreamTests.openFixture()
        let snippets = await BTREntityContextGatherer.gatherSnippets(
            forEntityNamed: "Alice", upThroughResourceHref: "does-not-exist.xhtml", in: publication)
        #expect(snippets.isEmpty)
    }

    @Test func respectsTheMaxSnippetCap() async throws {
        let publication = try await WordStreamTests.openFixture()
        // The last resource in the reading order — searching "the" (an
        // extremely common word) across the *whole* book up to here should
        // still stop at `maxSnippets`, not grow unbounded.
        let lastHref = publication.readingOrder.last!.url().string

        let snippets = await BTREntityContextGatherer.gatherSnippets(
            forEntityNamed: "the", upThroughResourceHref: lastHref, in: publication)

        let paragraphCount = snippets.isEmpty ? 0 : snippets.components(separatedBy: "\n\n").count
        #expect(paragraphCount <= BTREntityContextGatherer.maxSnippets)
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
