import Foundation
import SwiftData

/// An AI-generated "what happened since the start of this chapter" summary
/// (design-roadmap.md §2.9, §6.6.4). "Chapter" == Readium spine
/// item/resource for MVP, not a table-of-contents entry — simpler to
/// implement against `publication.readingOrder` and close enough in
/// practice (design-roadmap.md §10).
@Model
final class ChapterSummary {
    var id: UUID
    var chapterHref: String
    var chapterTitle: String?
    var content: String

    /// How far into the chapter this summary covers — the staleness key.
    /// Reused as-is while the reader's current position is at or before
    /// this locator's progression; regenerated once they've read further
    /// into the same chapter (design-roadmap.md §2.9).
    var sourceEndLocatorJSON: String

    var generatedAt: Date
    var book: Book?

    init(
        id: UUID = UUID(),
        chapterHref: String,
        chapterTitle: String? = nil,
        content: String,
        sourceEndLocatorJSON: String,
        generatedAt: Date = .now,
        book: Book? = nil
    ) {
        self.id = id
        self.chapterHref = chapterHref
        self.chapterTitle = chapterTitle
        self.content = content
        self.sourceEndLocatorJSON = sourceEndLocatorJSON
        self.generatedAt = generatedAt
        self.book = book
    }
}
