import Foundation
import ReadiumShared
import ReadiumStreamer
import Testing

/// Throwaway spike, not production code (see dev.md §9).
///
/// Verifies, against a real EPUB and the real Readium API (not just docs),
/// whether the Readium Swift Toolkit's `Publication`/`Locator`/`Content`
/// model gives us word-level addressing and round-trippable locators — the
/// two load-bearing assumptions behind the RSVP and Highlighted reading
/// modes, and behind storing "where you left off" in SwiftData.
struct ReadiumSpikeTests {
    /// Loads straight from disk next to this test file rather than through
    /// bundle resources — simplest thing that works for a spike.
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/alice.epub")
    }

    static func openFixture() async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        let fileURL = try #require(FileURL(url: fixtureURL))

        let asset = try await assetRetriever.retrieve(url: fileURL).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false
        ).get()

        return publication
    }

    @Test func opensEPUBAndExposesMetadata() async throws {
        let publication = try await Self.openFixture()

        print("SPIKE title:", publication.metadata.title ?? "nil")
        print("SPIKE language:", publication.metadata.language?.code.bcp47 ?? "nil")
        print("SPIKE readingOrder.count:", publication.readingOrder.count)

        #expect(publication.metadata.title != nil)
        #expect(!publication.readingOrder.isEmpty)

        switch await publication.tableOfContents() {
        case let .success(toc):
            print("SPIKE toc.count:", toc.count)
            for link in toc.prefix(5) {
                print("SPIKE toc entry:", link.title ?? "?", "->", link.href)
            }
            #expect(!toc.isEmpty)
        case let .failure(error):
            Issue.record("Failed to read table of contents: \(error)")
        }
    }

    @Test func contentAPIGivesWordLevelLocators() async throws {
        let publication = try await Self.openFixture()

        let content = try #require(publication.content(), "publication.content() returned nil — no ContentService for this format")

        let elements = await content.elements()
        print("SPIKE content element count:", elements.count)
        #expect(!elements.isEmpty)

        let textElements = elements.compactMap { $0 as? TextContentElement }
        #expect(!textElements.isEmpty, "expected at least one TextContentElement")

        let firstParagraph = try #require(
            textElements.first(where: { $0.role == .body }) ?? textElements.first
        )

        print("SPIKE first paragraph text:", (firstParagraph.text ?? "").prefix(160))
        print("SPIKE first paragraph locator href:", firstParagraph.locator.href)
        print("SPIKE first paragraph locator locations:", firstParagraph.locator.locations)

        // Word-level tokenization, driven directly by the Content API —
        // deliberately bypassing PublicationSpeechSynthesizer/AVSpeech so we
        // can drive our own RSVP timing engine off plain word+locator pairs.
        let wordTokenizer = makeTextContentTokenizer(
            defaultLanguage: publication.metadata.language,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .word, language: language)
            }
        )

        let wordElements = try wordTokenizer(firstParagraph)
        let words = wordElements
            .compactMap { $0 as? TextContentElement }
            .flatMap(\.segments)

        print("SPIKE word count in first paragraph:", words.count)
        for word in words.prefix(10) {
            print("SPIKE word:", word.text, "| href:", word.locator.href, "| locations:", word.locator.locations)
        }

        #expect(words.count > 3, "expected the first paragraph to tokenize into multiple words")

        // Each word gets its own Locator, but — important nuance — they all
        // share the same positional anchor (href + cssSelector/progression)
        // as the parent paragraph. What actually differs per word is
        // `locator.text.highlight` (the word's own text) plus its
        // before/after context snippet. So "word-level addressing" here
        // means "word-level text + context, anchored at paragraph
        // granularity" — not a distinct character-offset per word. That's
        // still enough to drive RSVP (we materialize our own word array up
        // front) and to resume mid-paragraph (fuzzy text-context matching,
        // the same technique Readium's own TTS highlighting relies on) —
        // but it means seeking must go through our own word index, not
        // through `locator.locations` alone.
        let distinctHrefs = Set(words.map(\.locator.href))
        #expect(distinctHrefs.count == 1, "expected all words in one paragraph to share the same href anchor")

        let distinctHighlights = Set(words.prefix(10).map { $0.locator.text.highlight })
        #expect(distinctHighlights.count == words.prefix(10).count, "expected each word's text.highlight to be distinct")
    }

    @Test func locatorRoundTripsThroughJSON() async throws {
        let publication = try await Self.openFixture()
        let content = try #require(publication.content())
        let elements = await content.elements()
        let firstText = try #require(elements.compactMap { $0 as? TextContentElement }.first)

        let original = firstText.locator
        let jsonString = try original.jsonString()
        print("SPIKE locator JSON:", jsonString)

        let decoded = try Locator(jsonString: jsonString)

        // NOT `decoded == original`: JSONSerialization round-trips the
        // `totalProgression`/`progression` Doubles through their string
        // representation and loses a few bits of precision (observed:
        // 0.012048192771084338 -> 0.01204819277108434), so strict equality
        // fails even though the locator is, for any practical "resume where
        // I left off" purpose, unchanged. Structural fields must match
        // exactly; progression only needs to match closely.
        #expect(decoded.href == original.href)
        #expect(decoded.mediaType == original.mediaType)
        #expect(decoded.text == original.text)
        #expect(decoded.locations.otherLocations.keys == original.locations.otherLocations.keys)
        let originalProgression = try #require(original.locations.totalProgression)
        let decodedProgression = try #require(decoded.locations.totalProgression)
        #expect(abs(originalProgression - decodedProgression) < 0.0000001)
    }
}
