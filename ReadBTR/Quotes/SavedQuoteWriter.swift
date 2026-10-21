import Foundation
@preconcurrency import ReadiumShared
import SwiftData

/// The one place every reading mode goes through to write a `SavedQuote`,
/// so Guided, Normal, and RSVP all store quotes the same way.
enum SavedQuoteWriter {
    /// Trims surrounding whitespace and collapses internal runs of
    /// whitespace (selections spanning line breaks come back with raw
    /// newlines). Returns `nil`, writing nothing, when there's no text left.
    @MainActor
    @discardableResult
    static func save(
        text rawText: String,
        start: Locator,
        end: Locator? = nil,
        book: Book,
        in context: ModelContext
    ) -> SavedQuote? {
        let text = normalized(rawText)
        guard !text.isEmpty else { return nil }

        let startJSON = (try? start.jsonString()) ?? ""
        let endJSON = (try? (end ?? start).jsonString()) ?? startJSON
        let quote = SavedQuote(text: text, startLocatorJSON: startJSON, endLocatorJSON: endJSON, book: book)
        context.insert(quote)
        try? context.save()
        return quote
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
