import Foundation
@preconcurrency import ReadiumShared

/// A word-by-word breakdown of a single resource (≈ chapter), each word
/// carrying its own `Locator` — the building block RSVP mode steps through
/// (design-roadmap.md §4.2).
///
/// Scoped to one resource, not the whole book: "chapter" == Readium
/// resource/spine item for MVP (design-roadmap.md §10), and building a
/// stream is cheap enough (proven in the phase-1 spike, dev.md §9) that
/// there's no need to materialize the entire book's words up front.
struct WordStream {
    let resourceHref: String
    let words: [TextContentElement.Segment]
}

extension WordStream {
    /// Builds the word stream for `href` by walking the publication's
    /// `Content` from that resource's start locator and tokenizing each
    /// text element to word granularity (the same technique proven in the
    /// phase-1 spike, dev.md §9), stopping as soon as content from a
    /// *different* resource appears — `Content` iterates across the whole
    /// reading order by default, so this clamps it to just one resource.
    static func build(for href: String, in publication: Publication) async -> WordStream? {
        guard
            let link = publication.readingOrder.first(where: { $0.url().string == href }),
            let startLocator = await publication.locate(link),
            let content = publication.content(from: startLocator)
        else {
            return nil
        }

        let wordTokenizer = makeTextContentTokenizer(
            defaultLanguage: publication.metadata.language,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .word, language: language)
            }
        )

        var words: [TextContentElement.Segment] = []
        for await element in content.sequence() {
            guard element.locator.href.string == href else {
                // Crossed into the next resource — this one is done.
                break
            }
            guard let textElement = element as? TextContentElement else { continue }
            let tokenized = (try? wordTokenizer(textElement)) ?? []
            words.append(contentsOf: tokenized.compactMap { $0 as? TextContentElement }.flatMap(\.segments))
        }

        return WordStream(resourceHref: href, words: words)
    }

    /// Words within `radius` of `index` on either side, clamped to this
    /// stream's own bounds — the ±100-word BTR entity-extraction context
    /// window (design-roadmap.md §6.6.3 step 1). Resource-clamped "for
    /// free": since a `WordStream` never crosses a resource boundary to
    /// begin with (`build(for:in:)` stops there), a window near either edge
    /// of the resource is simply shorter rather than reaching into an
    /// adjacent resource's stream — the accepted MVP simplification
    /// design-roadmap.md §10 calls out explicitly.
    func window(around index: Int, radius: Int) -> [TextContentElement.Segment] {
        guard words.indices.contains(index) else { return [] }
        let lower = max(words.startIndex, index - radius)
        let upper = min(words.endIndex, index + radius + 1)
        return Array(words[lower..<upper])
    }
}
