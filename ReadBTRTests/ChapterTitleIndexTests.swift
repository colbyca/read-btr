import Foundation
@preconcurrency import ReadiumShared
import Testing
@testable import ReadBTR

struct ChapterTitleIndexTests {
    @Test func resourceUsesItsOwnTOCTitle() {
        let index = ChapterTitleIndex(
            readingOrderHrefs: ["cover.xhtml", "ch1.xhtml", "ch2.xhtml"],
            tocEntries: [(href: "ch1.xhtml", title: "Chapter One"), (href: "ch2.xhtml", title: "Chapter Two")]
        )
        #expect(index.title(forResourceHref: "ch1.xhtml") == "Chapter One")
        #expect(index.title(forResourceHref: "ch2.xhtml") == "Chapter Two")
    }

    @Test func resourcesBeforeFirstTOCEntryHaveNoTitle() {
        let index = ChapterTitleIndex(
            readingOrderHrefs: ["cover.xhtml", "ch1.xhtml"],
            tocEntries: [(href: "ch1.xhtml", title: "Chapter One")]
        )
        #expect(index.title(forResourceHref: "cover.xhtml") == nil)
    }

    @Test func untitledResourceInheritsPrecedingChapter() {
        let index = ChapterTitleIndex(
            readingOrderHrefs: ["ch1.xhtml", "ch1-part2.xhtml", "ch2.xhtml"],
            tocEntries: [(href: "ch1.xhtml", title: "Chapter One"), (href: "ch2.xhtml", title: "Chapter Two")]
        )
        #expect(index.title(forResourceHref: "ch1-part2.xhtml") == "Chapter One")
    }

    @Test func fragmentsAreIgnoredAndFirstEntryWins() {
        let index = ChapterTitleIndex(
            readingOrderHrefs: ["book.xhtml"],
            tocEntries: [(href: "book.xhtml#c1", title: "One"), (href: "book.xhtml#c2", title: "Two")]
        )
        #expect(index.title(forResourceHref: "book.xhtml") == "One")
        #expect(index.title(forResourceHref: "book.xhtml#anything") == "One")
    }

    @Test func blankTitlesAreSkipped() {
        let index = ChapterTitleIndex(
            readingOrderHrefs: ["ch1.xhtml", "ch2.xhtml"],
            tocEntries: [(href: "ch1.xhtml", title: "Real"), (href: "ch2.xhtml", title: "  ")]
        )
        #expect(index.title(forResourceHref: "ch2.xhtml") == "Real")
    }

    @MainActor
    @Test func fixtureChaptersResolveToTitles() async throws {
        let publication = try await WordStreamTests.openFixture()
        let index = await ChapterTitleIndex.make(for: publication)
        let titled = publication.readingOrder.compactMap { index.title(forResourceHref: $0.url().string) }
        #expect(!titled.isEmpty, "expected alice.epub's reading order to map to TOC titles")
    }
}
