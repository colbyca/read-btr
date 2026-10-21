import Foundation
import SwiftData

/// A user-saved quote (design-roadmap.md §2.11, §6.6.1). Written through
/// `SavedQuoteWriter` from every reading mode: Guided Reading's multi-word
/// selection tooltip, Normal mode's native selection menu, and RSVP's
/// long-press tooltip (which saves the sentence around the current word).
/// Listed in `SavedQuotesView`.
@Model
final class SavedQuote {
    var id: UUID

    /// Denormalized copy of the quoted text, so display doesn't need to
    /// re-fetch from the publication.
    var text: String

    var startLocatorJSON: String
    var endLocatorJSON: String
    var note: String?
    var createdAt: Date
    var book: Book?

    init(
        id: UUID = UUID(),
        text: String,
        startLocatorJSON: String,
        endLocatorJSON: String,
        note: String? = nil,
        createdAt: Date = .now,
        book: Book? = nil
    ) {
        self.id = id
        self.text = text
        self.startLocatorJSON = startLocatorJSON
        self.endLocatorJSON = endLocatorJSON
        self.note = note
        self.createdAt = createdAt
        self.book = book
    }
}
