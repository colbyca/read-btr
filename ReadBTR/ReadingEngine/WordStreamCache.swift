import Foundation
@preconcurrency import ReadiumShared

/// In-memory, per-resource cache of `WordStream`s (design-roadmap.md §4.2).
///
/// Deliberately owned by whatever reading session needs it, not a
/// permanent app-wide singleton — "evicted on mode exit" just means letting
/// the owning view model's instance be deallocated when the mode's view
/// disappears. `@MainActor`, matching the concurrency convention already
/// used by `AppSettingsStore`/`BookImporter` rather than introducing a
/// second isolation mechanism (a Swift `actor`) into the codebase.
@MainActor
final class WordStreamCache {
    private var streamsByHref: [String: WordStream] = [:]

    func stream(for href: String, in publication: Publication) async -> WordStream? {
        if let cached = streamsByHref[href] {
            return cached
        }
        guard let stream = await WordStream.build(for: href, in: publication) else {
            return nil
        }
        streamsByHref[href] = stream
        return stream
    }

    func reset() {
        streamsByHref.removeAll()
    }

    /// Returns the first non-empty word stream at or after `href` in the
    /// publication's reading order.
    ///
    /// Books commonly *start* on a resource with no extractable text — the
    /// real `alice.epub` fixture's very first reading-order resource is a
    /// cover-image wrapper page, confirmed empirically, not a rare edge
    /// case. Resolving an initial reading position needs to skip forward
    /// past resources like that rather than landing RSVP on an unusable
    /// empty stream.
    func firstNonEmptyStream(from href: String, in publication: Publication) async -> WordStream? {
        let hrefs = publication.readingOrder.map { $0.url().string }
        guard var index = hrefs.firstIndex(of: href) else { return nil }

        while index < hrefs.count {
            if let candidate = await stream(for: hrefs[index], in: publication), !candidate.words.isEmpty {
                return candidate
            }
            index += 1
        }
        return nil
    }
}
