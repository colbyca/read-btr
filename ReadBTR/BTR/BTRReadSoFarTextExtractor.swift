import Foundation
@preconcurrency import ReadiumShared

/// Gathers the text of the whole book from the very start up to the
/// reader's position — the context Q&A answers are grounded in. This is
/// dev.md §3's spoiler-avoidance rule for Q&A ("the request should only
/// include text up to the reader's current position"), and the same
/// "just pass the text" approach dev.md §3 picks over RAG for v1.
enum BTRReadSoFarTextExtractor {
    /// Upper bound on how much text goes into one request. About 150k
    /// tokens — well inside Gemini's context window, but it keeps cost per
    /// question sane on a long book, since the reader pays per token (BYOK).
    /// When the read-so-far text is longer, the *most recent* text is kept,
    /// since questions are usually about what just happened.
    static let maxCharacters = 600_000

    struct Result: Equatable {
        var text: String
        /// True when earlier text was dropped to fit `maxCharacters`.
        var wasTruncated: Bool
    }

    static func extractText(
        upTo locator: Locator, in publication: Publication, maxCharacters: Int = maxCharacters
    ) async -> Result? {
        let hrefs = publication.readingOrder.map { $0.url().string }
        let currentHref = locator.href.string
        guard let cutoffIndex = hrefs.firstIndex(of: currentHref) else { return nil }

        var pieces: [String] = []
        for href in hrefs[..<cutoffIndex] {
            pieces += await BTRChapterTextExtractor.textPieces(ofResource: href, upToProgression: nil, in: publication)
        }
        pieces += await BTRChapterTextExtractor.textPieces(
            ofResource: currentHref, upToProgression: locator.locations.progression, in: publication)

        guard !pieces.isEmpty else { return nil }
        return truncatingFromStart(pieces.joined(separator: "\n\n"), maxCharacters: maxCharacters)
    }

    /// Keeps the last `maxCharacters` characters, starting at a paragraph
    /// break where possible so the kept text doesn't open mid-sentence.
    static func truncatingFromStart(_ text: String, maxCharacters: Int) -> Result {
        guard text.count > maxCharacters, maxCharacters > 0 else { return Result(text: text, wasTruncated: false) }
        var tail = String(text.suffix(maxCharacters))
        if let paragraphBreak = tail.range(of: "\n\n") {
            tail = String(tail[paragraphBreak.upperBound...])
        }
        return Result(text: tail, wasTruncated: true)
    }
}
