import Foundation
import SwiftData

/// A user-saved quote — populated by Guided Reading's multi-word "save
/// quote" action (design-roadmap.md §2.11, §6.6.1).
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
