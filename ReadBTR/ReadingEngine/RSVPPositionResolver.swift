import Foundation
@preconcurrency import ReadiumShared

/// Turns an arbitrary `Locator` (from Normal/Guided Reading) into a word
/// index in a `WordStream` (design-roadmap.md §4.3).
///
/// There's no free lunch here: the phase-1 spike found that Readium's
/// word-level locators share their parent paragraph's positional anchor and
/// differ only by `text.highlight`/context (dev.md §4.1) — so an arbitrary
/// incoming locator can only be *approximated* against a word array, not
/// resolved exactly, unless it happens to already carry the same text
/// context our own word locators produce.
enum RSVPPositionResolver {
    /// Search window, in words, on either side of the progression estimate.
    private static let refinementWindow = 25

    static func wordIndex(for locator: Locator, in stream: WordStream) -> Int {
        let words = stream.words
        guard !words.isEmpty else { return 0 }

        let progression = locator.locations.progression ?? 0
        let estimate = clamp(Int(progression * Double(words.count)), to: words.indices)

        // Refine only when the incoming locator actually carries a word-level
        // text snippet to match against — which is exactly the case when
        // resuming from a previously-saved RSVP position (a word segment's
        // own locator, produced by this same tokenizer), and exactly *not*
        // the case for a plain Normal/Guided navigation locator, which only
        // carries `locations.progression`. In the latter case there's
        // nothing to refine against, so this deliberately no-ops and falls
        // through to the estimate — approximate beats blocking, and it's
        // rarely far off since progression is monotonic within a resource.
        guard let highlight = locator.text.highlight, !highlight.isEmpty else {
            return estimate
        }

        let windowStart = clamp(estimate - refinementWindow, to: words.indices)
        let windowEnd = clamp(estimate + refinementWindow, to: words.indices)

        if let match = words[windowStart...windowEnd].firstIndex(where: { $0.locator.text.highlight == highlight }) {
            return match
        }

        return estimate
    }

    private static func clamp(_ value: Int, to range: Range<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound - 1)
    }
}
