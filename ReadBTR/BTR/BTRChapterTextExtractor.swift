import Foundation
@preconcurrency import ReadiumShared

/// Extracts the text of one chapter (== Readium resource/spine item, design-
/// roadmap.md §10) up to a given position in it, for the "summarize since
/// start of chapter" BTR option (§6.6.4) and comprehension checks: range is
/// `[start of current resource, current locator]`.
enum BTRChapterTextExtractor {
    static func extractText(upTo locator: Locator, in publication: Publication) async -> String? {
        let pieces = await textPieces(
            ofResource: locator.href.string, upToProgression: locator.locations.progression, in: publication)
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    /// Every text element of one resource, in order, stopping once an
    /// element's progression passes `cutoffProgression` (nil = the whole
    /// resource). Shared by the chapter extractor above and
    /// `BTRReadSoFarTextExtractor`.
    static func textPieces(
        ofResource href: String, upToProgression cutoffProgression: Double?, in publication: Publication
    ) async -> [String] {
        guard
            let link = publication.readingOrder.first(where: { $0.url().string == href }),
            let startLocator = await publication.locate(link),
            let content = publication.content(from: startLocator)
        else {
            return []
        }

        var pieces: [String] = []
        for await element in content.sequence() {
            guard element.locator.href.string == href else {
                // Crossed into the next resource — this one is done.
                break
            }
            // Stop once we've passed the reader's own position — mirrors
            // `WordStream.build`'s resource-boundary stop, just cutting off
            // mid-resource instead of at its end, so the result only
            // covers text the reader has actually reached.
            let elementProgression = element.locator.locations.progression
            if let cutoffProgression, let elementProgression, elementProgression > cutoffProgression {
                break
            }
            guard let textElement = element as? TextContentElement, let text = textElement.text, !text.isEmpty else {
                continue
            }
            pieces.append(text)
        }
        return pieces
    }
}
