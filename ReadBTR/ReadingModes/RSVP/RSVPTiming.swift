import Foundation

/// Spritz-style pacing: a base interval derived from words-per-minute,
/// stretched for longer words and for words immediately followed by
/// punctuation, when `RSVPSettings.smartTimingEnabled` is on (dev.md §2.1).
///
/// `after` should be the word's `Locator.text.after` context snippet, not
/// the word's own text — confirmed empirically against the real `alice.epub`
/// fixture, the word-unit tokenizer strips punctuation out of the word text
/// itself, but the mark immediately following a word survives as the first
/// character of its `text.after` snippet, which is what this actually reads.
enum RSVPTiming {
    static func delay(forWord word: String, after: String?, settings: RSVPSettings) -> TimeInterval {
        let base = 60.0 / Double(max(settings.wordsPerMinute, 1))
        guard settings.smartTimingEnabled else { return base }

        let lengthFactor = 1.0 + Double(max(0, word.count - 6)) * 0.08
        return base * lengthFactor * punctuationFactor(after: after)
    }

    private static func punctuationFactor(after: String?) -> Double {
        switch after?.first {
        case ".", "!", "?":
            2.2
        case ",", ";", ":":
            1.4
        default:
            1.0
        }
    }
}
