import Foundation
@preconcurrency import ReadiumShared

/// Small shared helper for stepping between adjacent resources in a
/// publication's reading order. Used by both RSVP (`RSVPViewModel.step`) and
/// Guided Reading (`GuidedReadingViewModel`'s playback advance) whenever a
/// mode's current word/segment runs off the end of its resource.
enum PublicationReadingOrder {
    static func adjacentResourceHref(after href: String, in publication: Publication, forward: Bool) -> String? {
        let hrefs = publication.readingOrder.map { $0.url().string }
        guard let index = hrefs.firstIndex(of: href) else { return nil }
        let adjacentIndex = forward ? index + 1 : index - 1
        guard hrefs.indices.contains(adjacentIndex) else { return nil }
        return hrefs[adjacentIndex]
    }
}
