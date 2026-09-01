import Foundation
@preconcurrency import ReadiumShared

/// Resolves an arbitrary reading-position `Locator` (from any of the three
/// reading modes — this is what makes it a `ReadingEngine` concern rather
/// than something BTR-specific) into the flat text of the ±N-word window
/// around it, for the BTR menu's entity-extraction call (design-roadmap.md
/// §6.6.3 step 1: "slice ±100 words from the same `WordStream`").
///
/// Deliberately thin: all the actual position resolution is
/// `RSVPPositionResolver`/`WordStreamCache`, already proven by
/// `Book.currentRSVPIndex` — this just chains "locator → stream → index →
/// window → joined text" into one call so `BTRMenuViewModel` doesn't have
/// to re-derive that chain itself.
enum BTRContextWindow {
    static func snippet(
        around locator: Locator, in publication: Publication, cache: WordStreamCache, radius: Int
    ) async -> String? {
        guard let stream = await cache.stream(for: locator.href.string, in: publication), !stream.words.isEmpty else {
            return nil
        }
        let index = RSVPPositionResolver.wordIndex(for: locator, in: stream)
        let window = stream.window(around: index, radius: radius)
        guard !window.isEmpty else { return nil }
        return window.map(\.text).joined(separator: " ")
    }
}
