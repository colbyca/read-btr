import Foundation
@preconcurrency import ReadiumShared
import Testing
@testable import ReadBTR

// MARK: - WordStream, against the real fixture

@MainActor
struct WordStreamTests {
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/alice.epub")
    }

    static func openFixture() async throws -> Publication {
        let loader = PublicationLoader()
        return try await loader.open(fileURL: fixtureURL)
    }

    @Test func buildProducesWordsAllSharingTheRequestedResource() async throws {
        let publication = try await Self.openFixture()
        // Index 1: the first real chapter, per the phase-1 spike's TOC dump
        // (index 0 is the Gutenberg boilerplate/title page).
        let chapterHref = publication.readingOrder[1].url().string

        let stream = await WordStream.build(for: chapterHref, in: publication)
        let words = try #require(stream?.words)

        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.locator.href.string == chapterHref })

        // Sanity bound: a single chapter, not the whole ~26,000-word book —
        // proves the resource-boundary clamp in WordStream.build actually
        // stopped iterating rather than consuming the entire reading order.
        #expect(words.count < 5000)
    }

    @Test func buildReturnsNilForAnUnknownHref() async throws {
        let publication = try await Self.openFixture()
        let stream = await WordStream.build(for: "does-not-exist.xhtml", in: publication)
        #expect(stream == nil)
    }
}

// MARK: - WordStreamCache, against the real fixture

@MainActor
struct WordStreamCacheTests {
    @Test func cacheReturnsConsistentResultsAcrossRepeatedLookups() async throws {
        let publication = try await WordStreamTests.openFixture()
        let chapterHref = publication.readingOrder[1].url().string
        let cache = WordStreamCache()

        let first = try #require(await cache.stream(for: chapterHref, in: publication))
        let second = try #require(await cache.stream(for: chapterHref, in: publication))

        #expect(first.words.count == second.words.count)
        #expect(first.words.map(\.text) == second.words.map(\.text))
    }

    @Test func resetAllowsRebuildingAfterEviction() async throws {
        let publication = try await WordStreamTests.openFixture()
        let chapterHref = publication.readingOrder[1].url().string
        let cache = WordStreamCache()

        _ = await cache.stream(for: chapterHref, in: publication)
        cache.reset()
        let rebuilt = await cache.stream(for: chapterHref, in: publication)

        #expect(rebuilt != nil)
    }

    @Test func firstNonEmptyStreamSkipsPastAnEmptyLeadingResource() async throws {
        let publication = try await WordStreamTests.openFixture()
        let cache = WordStreamCache()

        // alice.epub's very first reading-order resource is a cover-image
        // wrapper page with no extractable text — confirmed empirically,
        // not assumed. This is exactly the case RSVP's initial position
        // resolution has to handle (Book.currentRSVPIndex): a book
        // commonly *starts* on a resource with zero words.
        let firstHref = publication.readingOrder[0].url().string
        let firstStream = try #require(await cache.stream(for: firstHref, in: publication))
        #expect(firstStream.words.isEmpty, "expected alice.epub's first resource to have no extractable text")

        let resolved = try #require(await cache.firstNonEmptyStream(from: firstHref, in: publication))
        #expect(!resolved.words.isEmpty)
        #expect(resolved.resourceHref != firstHref)
    }
}

// MARK: - RSVPPositionResolver, synthetic data (no file I/O needed)

struct RSVPPositionResolverTests {
    /// A locator whose only meaningful field is `text.highlight` — enough
    /// to stand in for a word segment's own locator without needing a real
    /// publication.
    static func makeLocator(highlight: String? = nil, progression: Double? = nil) throws -> Locator {
        var json: [String: Any] = [
            "href": "chapter1.xhtml",
            "type": "application/xhtml+xml",
        ]
        var locations: [String: Any] = [:]
        if let progression { locations["progression"] = progression }
        if !locations.isEmpty { json["locations"] = locations }
        if let highlight { json["text"] = ["highlight": highlight] }

        let data = try JSONSerialization.data(withJSONObject: json)
        let jsonString = String(data: data, encoding: .utf8)!
        return try Locator(jsonString: jsonString)
    }

    static func makeStream(wordCount: Int) throws -> WordStream {
        let words = try (0 ..< wordCount).map { index in
            TextContentElement.Segment(
                locator: try makeLocator(highlight: "word\(index)"),
                text: "word\(index)"
            )
        }
        return WordStream(resourceHref: "chapter1.xhtml", words: words)
    }

    @Test func emptyStreamReturnsZero() throws {
        let stream = WordStream(resourceHref: "chapter1.xhtml", words: [])
        let locator = try Self.makeLocator(progression: 0.5)
        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 0)
    }

    @Test func progressionOnlyLocatorFallsBackToEstimate() throws {
        // No `text.highlight` on the incoming locator — nothing to refine
        // against, so this exercises the pure progression-estimate path
        // (the case for a plain Normal/Guided navigation locator).
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(progression: 0.5)

        let index = RSVPPositionResolver.wordIndex(for: locator, in: stream)
        #expect(index == 50)
    }

    @Test func progressionZeroResolvesToFirstWord() throws {
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(progression: 0)
        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 0)
    }

    @Test func progressionOneClampsToLastWordNotOutOfBounds() throws {
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(progression: 1.0)
        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 99)
    }

    @Test func matchingHighlightWithinWindowResolvesExactly() throws {
        // Estimate from progression alone would land near word 50; the
        // *actual* target (word 45) is within the ±25 refinement window, so
        // this should resolve exactly rather than settling for the estimate.
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(highlight: "word45", progression: 0.5)

        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 45)
    }

    @Test func highlightOutsideWindowFallsBackToEstimate() throws {
        // "word90" exists in the stream, but it's far outside the
        // refinement window around progression 0.1's estimate (word 10) —
        // the resolver should not scan the whole array looking for it, it
        // should fall back to the estimate.
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(highlight: "word90", progression: 0.1)

        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 10)
    }

    @Test func nonMatchingHighlightFallsBackToEstimate() throws {
        let stream = try Self.makeStream(wordCount: 100)
        let locator = try Self.makeLocator(highlight: "not-in-the-stream", progression: 0.5)

        #expect(RSVPPositionResolver.wordIndex(for: locator, in: stream) == 50)
    }
}
