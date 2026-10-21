import Foundation
@preconcurrency import ReadiumShared

/// The sentence around a given word — what RSVP's Save Quote stores, since
/// a single flashed word on its own isn't much of a quote.
struct WordStreamSentence: Equatable {
    let range: ClosedRange<Int>
    let text: String
}

extension WordStream {
    /// Caps how far the sentence search walks in either direction, so text
    /// with no sentence punctuation (verse, lists, headings) doesn't turn
    /// into a whole-chapter "quote".
    static let maxSentenceRadius = 60

    /// Finds the sentence containing `index` by walking outward to the
    /// nearest sentence-ending word on each side. A word ends a sentence
    /// when its `Locator.text.after` starts with `.`, `!`, or `?` (the
    /// word tokenizer strips punctuation from the word text itself, but
    /// it survives at the start of `after` — see `RSVPTiming`).
    ///
    /// Punctuation between words is rebuilt from each word's `after`
    /// snippet, so the saved text reads like the book ("said the Hatter,
    /// sighing.") rather than a bare list of words.
    func sentence(around index: Int, maxRadius: Int = WordStream.maxSentenceRadius) -> WordStreamSentence? {
        guard words.indices.contains(index) else { return nil }

        var start = index
        while start > words.startIndex, index - start < maxRadius, !Self.endsSentence(words[start - 1]) {
            start -= 1
        }

        var end = index
        while end < words.endIndex - 1, end - index < maxRadius, !Self.endsSentence(words[end]) {
            end += 1
        }

        var text = ""
        for position in start...end {
            let word = words[position]
            text += word.text
            if position < end {
                text += Self.gap(after: word, before: words[position + 1])
            } else {
                text += Self.trailingPunctuation(after: word)
            }
        }
        return WordStreamSentence(range: start...end, text: text)
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let closingMarks: Set<Character> = [
        ".", "!", "?", "…", ",", ";", ":", "\"", "'", "”", "’", ")", "]",
    ]

    private static func endsSentence(_ word: TextContentElement.Segment) -> Bool {
        guard let first = word.locator.text.after?.first else { return false }
        return sentenceEnders.contains(first)
    }

    /// Whatever sits between two adjacent words in the source text — the
    /// prefix of `previous`'s `after` snippet up to where `next` begins.
    /// Falls back to a single space when the snippet doesn't contain the
    /// next word (snippets are short and can be cut off).
    private static func gap(after previous: TextContentElement.Segment, before next: TextContentElement.Segment) -> String {
        guard
            let after = previous.locator.text.after,
            !next.text.isEmpty,
            let range = after.range(of: next.text)
        else {
            return " "
        }
        let between = String(after[after.startIndex..<range.lowerBound])
        // Letters in the gap mean the match landed inside another word
        // (e.g. "a" inside "cat"), and a long gap means it was a later
        // repeat — either way it isn't the adjacent word.
        guard between.count <= 12, !between.contains(where: { $0.isLetter || $0.isNumber }) else { return " " }
        return collapsingWhitespace(between)
    }

    /// Each run of whitespace (including line breaks) becomes one space.
    private static func collapsingWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasWhitespace { result.append(" ") }
                lastWasWhitespace = true
            } else {
                result.append(character)
                lastWasWhitespace = false
            }
        }
        return result
    }

    /// Closing punctuation and quote marks right after the sentence's last
    /// word (e.g. `."` or `!’`).
    private static func trailingPunctuation(after word: TextContentElement.Segment) -> String {
        guard let after = word.locator.text.after else { return "" }
        return String(after.prefix(while: { closingMarks.contains($0) }))
    }
}
