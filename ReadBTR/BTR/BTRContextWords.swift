import Foundation
@preconcurrency import ReadiumShared

/// One word of the passage shown at the top of the BTR chat.
struct BTRContextWord: Identifiable, Equatable {
    /// Position in the passage, 0-based.
    let id: Int
    /// The word as displayed, with any punctuation that touches it.
    let text: String
    /// Whether this is (part of) the word the reader opened the chat from.
    let isAnchor: Bool
}

/// Builds the passage shown at the top of the BTR chat: the word(s) the
/// chat was opened from, plus `radius` words on either side
/// (design-roadmap.md §6.6.2). Pure functions over a `WordStream`, so the
/// tricky parts are unit-testable without a publication.
enum BTRContextWords {
    /// "10 previous and 10 subsequent words".
    static let radius = 10

    /// A long text selection is trimmed to this many words, so the passage
    /// stays a glanceable strip rather than a whole paragraph.
    static let maxAnchorWords = 30

    static func build(around locator: Locator, in stream: WordStream, radius: Int = radius) -> [BTRContextWord] {
        guard !stream.words.isEmpty else { return [] }
        let anchor = anchorRange(for: locator, in: stream)
        let lower = max(0, anchor.lowerBound - radius)
        let upper = min(stream.words.count - 1, anchor.upperBound + radius)
        let texts = displayTexts(for: Array(stream.words[lower...upper]))
        return texts.enumerated().map { offset, text in
            BTRContextWord(id: offset, text: text, isAnchor: anchor.contains(lower + offset))
        }
    }

    /// Which words of `stream` the locator points at. RSVP passes a single
    /// word's own locator; Normal and Guided Reading pass a text selection,
    /// which can span several words and only carries an approximate
    /// position. Either way: find the run of words matching the locator's
    /// highlighted text that's closest to where its progression says it
    /// should be, falling back to that estimate alone.
    static func anchorRange(for locator: Locator, in stream: WordStream) -> ClosedRange<Int> {
        let estimate = RSVPPositionResolver.wordIndex(for: locator, in: stream)
        let tokens = normalizedTokens(locator.text.highlight ?? "")
        guard !tokens.isEmpty else { return estimate...estimate }

        // RSVP's word locators already resolve exactly.
        if tokens.count == 1, normalize(stream.words[estimate].text) == tokens[0] {
            return estimate...estimate
        }

        let words = stream.words.map { normalize($0.text) }
        let length = tokens.count
        guard length <= words.count else { return estimate...estimate }

        var best: Int?
        for start in 0...(words.count - length) where words[start] == tokens[0] {
            guard Array(words[start..<(start + length)]) == tokens else { continue }
            if best.map({ abs(start - estimate) < abs($0 - estimate) }) ?? true {
                best = start
            }
        }
        guard let start = best else { return estimate...estimate }
        let end = start + min(length, maxAnchorWords) - 1
        return start...end
    }

    /// Word texts with the punctuation between words put back. Word
    /// segments only carry the bare word, but each one's locator also
    /// carries the text that follows it, so the gap up to the next word
    /// can be recovered: punctuation before the gap's first space sticks to
    /// this word ("Alice,"), punctuation after its last space to the next
    /// one ("“Oh").
    static func displayTexts(for words: [TextContentElement.Segment]) -> [String] {
        var texts = words.map(\.text)
        for index in words.indices.dropLast() {
            guard let gap = gap(after: words[index], before: words[index + 1]) else { continue }
            let trimmed = gap.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let firstSpace = gap.firstIndex(where: \.isWhitespace),
                let lastSpace = gap.lastIndex(where: \.isWhitespace)
            {
                let trailing = String(gap[..<firstSpace])
                let leading = String(gap[gap.index(after: lastSpace)...])
                texts[index] += trailing
                texts[index + 1] = leading + texts[index + 1]
            } else {
                // No space at all, e.g. a hyphen or an em dash between words.
                texts[index] += gap
            }
        }
        // The passage's edges: punctuation touching the first and last word.
        if let first = words.first, let before = first.locator.text.before {
            let touching = String(before.reversed().prefix(while: { !$0.isWhitespace }).reversed())
            if isPunctuationOnly(touching) { texts[0] = touching + texts[0] }
        }
        if let last = words.last, let after = last.locator.text.after {
            let touching = String(after.prefix(while: { !$0.isWhitespace }))
            if isPunctuationOnly(touching) { texts[texts.count - 1] += touching }
        }
        return texts
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 3
            && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }
    }

    private static func gap(after word: TextContentElement.Segment, before next: TextContentElement.Segment)
        -> String?
    {
        guard let after = word.locator.text.after, !next.text.isEmpty,
            let nextRange = after.range(of: next.text)
        else { return nil }
        let gap = String(after[..<nextRange.lowerBound])
        // A long gap means the match is probably a later repeat of the
        // word, not the next one; leave the words bare instead.
        return gap.count <= 6 ? gap : nil
    }

    static func normalizedTokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// The passage as one string, and the selected words in order — what
    /// the prompt gets. Gaps in a non-contiguous selection become "…".
    static func focus(for words: [BTRContextWord], selected: Set<Int>) -> PromptBuilder.ChatFocus? {
        guard !words.isEmpty else { return nil }
        let passage = words.map(\.text).joined(separator: " ")
        let picked = words.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return PromptBuilder.ChatFocus(passage: passage, selectedText: nil) }
        var pieces: [String] = []
        var previousID: Int?
        for word in picked {
            if let previousID, word.id != previousID + 1 { pieces.append("…") }
            pieces.append(word.text)
            previousID = word.id
        }
        return PromptBuilder.ChatFocus(passage: passage, selectedText: pieces.joined(separator: " "))
    }
}
