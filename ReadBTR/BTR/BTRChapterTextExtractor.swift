import Foundation
@preconcurrency import ReadiumShared

/// Extracts the text of one chapter (== Readium resource/spine item, design-
/// roadmap.md §10) up to a given position in it, for the "summarize since
/// start of chapter" BTR option (§6.6.4): range is `[start of current
/// resource, current locator]`.
enum BTRChapterTextExtractor {
    static func extractText(upTo locator: Locator, in publication: Publication) async -> String? {
        let href = locator.href.string
        guard
            let link = publication.readingOrder.first(where: { $0.url().string == href }),
            let startLocator = await publication.locate(link),
            let content = publication.content(from: startLocator)
        else {
            return nil
        }

        let cutoffProgression = locator.locations.progression
        var pieces: [String] = []
        for await element in content.sequence() {
            guard element.locator.href.string == href else {
                // Crossed into the next resource — this one is done.
                break
            }
            // Stop once we've passed the reader's own position — mirrors
            // `WordStream.build`'s resource-boundary stop, just cutting off
            // mid-resource instead of at its end, so the summary only
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
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }
}
