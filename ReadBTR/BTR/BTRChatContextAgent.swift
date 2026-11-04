import Foundation
@preconcurrency import ReadiumShared

/// Gathers the book text a BTR chat question is answered from
/// (design-roadmap.md §6.6.3), across every title the reader is allowed to
/// see:
///
/// - books *earlier* in any collection the open book belongs to, in full;
/// - the open book, from its start up to the reader's position;
/// - never a book *later* in a collection, and never past the reader's
///   position.
///
/// When all of that fits comfortably in one request, it's all sent ("just
/// pass the text", dev.md §3). When it doesn't — a long series — the agent
/// takes two steps: it asks the model for search terms
/// (`PromptBuilder.retrievalPlanPrompt`), then searches the readable text
/// for paragraphs matching them, and sends those plus the most recent text
/// before the reader's position. The search only ever runs over readable
/// text, so the retrieved context is spoiler-free by construction.
@MainActor
final class BTRChatContextAgent {
    /// What one book contributes before loading: either an already-open
    /// publication (the open book) or a library book to open on demand.
    struct Source {
        let bookID: UUID
        let title: String
        let isCurrentBook: Bool
        let load: @MainActor () async -> [BTRTextPassage]?
    }

    /// The excerpts for one question, plus which titles were used.
    struct Context: Equatable {
        var excerpts: String
        var usedSearch: Bool
        var unavailableTitles: [String]
    }

    /// Up to this many characters (~100k tokens) is sent whole.
    static let fullTextLimit = 400_000
    /// When searching: how much of the most recent text before the
    /// reader's position always goes along, and how much room the search
    /// hits get. ~35k tokens together.
    static let recentTextBudget = 60_000
    static let searchBudget = 80_000

    private let sources: [Source]
    private var loadedTexts: [BTRBookText]?
    private var unavailableTitles: [String] = []

    init(sources: [Source]) {
        self.sources = sources
    }

    /// The titles in reading order, open book last.
    var titles: [String] { sources.map(\.title) }

    /// Loads (once) every source's readable text. `onStatus` reports which
    /// book is being read, for the chat's progress line.
    func loadTexts(onStatus: (String) -> Void) async -> [BTRBookText] {
        if let loadedTexts { return loadedTexts }
        var texts: [BTRBookText] = []
        for source in sources {
            onStatus("Reading “\(source.title)”…")
            if let passages = await source.load(), !passages.isEmpty {
                texts.append(
                    BTRBookText(
                        bookID: source.bookID, title: source.title, isCurrentBook: source.isCurrentBook,
                        passages: passages))
            } else if !source.isCurrentBook {
                unavailableTitles.append(source.title)
            }
        }
        loadedTexts = texts
        return texts
    }

    func gatherContext(
        question: String,
        focus: PromptBuilder.ChatFocus?,
        recentConversation: [AIChatMessage],
        provider: AIProvider,
        onStatus: (String) -> Void
    ) async -> Context {
        let texts = await loadTexts(onStatus: onStatus)
        let total = texts.reduce(0) { $0 + $1.characterCount }
        if total <= Self.fullTextLimit {
            return Context(
                excerpts: Self.formatFullText(texts), usedSearch: false, unavailableTitles: unavailableTitles)
        }

        onStatus("Searching what you’ve read…")
        var terms: [String] = []
        let planPrompt = PromptBuilder.retrievalPlanPrompt(
            question: question, focus: focus, recentConversation: recentConversation,
            bookTitles: texts.map(\.title))
        if let response = try? await provider.generateText(
            prompt: planPrompt, responseSchema: .json(schema: PromptBuilder.retrievalPlanSchema)),
            let data = response.data(using: .utf8),
            let plan = try? JSONDecoder().decode(RetrievalPlan.self, from: data)
        {
            terms = plan.searchTerms
        }
        // If planning fails, fall back to the question's own key words
        // rather than failing the whole answer.
        terms += Self.fallbackTerms(question: question, selectedText: focus?.selectedText)

        let excerpts = Self.retrieve(
            terms: Array(terms.prefix(PromptBuilder.maxSearchTerms * 2)), from: texts,
            recentBudget: Self.recentTextBudget, searchBudget: Self.searchBudget)
        return Context(excerpts: excerpts, usedSearch: true, unavailableTitles: unavailableTitles)
    }

    private struct RetrievalPlan: Decodable {
        var searchTerms: [String]
    }

    // MARK: - Pure helpers (unit-tested)

    static func header(for text: BTRBookText) -> String {
        text.isCurrentBook
            ? "=== \(text.title) (current book, from the start up to the reader's position) ==="
            : "=== \(text.title) (an earlier book the reader has finished) ==="
    }

    /// Every readable passage, grouped under book and chapter headings.
    static func formatFullText(_ texts: [BTRBookText]) -> String {
        texts.map { text in
            header(for: text) + "\n" + formatPassages(text.passages[...])
        }.joined(separator: "\n\n")
    }

    private static func formatPassages(_ passages: ArraySlice<BTRTextPassage>, gapsBefore: Set<Int> = []) -> String {
        var lines: [String] = []
        var currentChapter: String?
        for index in passages.indices {
            let passage = passages[index]
            if gapsBefore.contains(index) { lines.append("[…]") }
            if passage.chapter != currentChapter {
                lines.append("--- \(passage.chapter) ---")
                currentChapter = passage.chapter
            }
            lines.append(passage.text)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Keyword retrieval over readable text. The open book's most recent
    /// `recentBudget` characters always go along (questions are usually
    /// about what just happened); the rest of the readable text — earlier
    /// books and the open book's earlier chapters — is scored by how often
    /// the search terms appear, and the best paragraphs (each with the one
    /// before it, for context) fill `searchBudget`. Output keeps reading
    /// order.
    static func retrieve(terms rawTerms: [String], from texts: [BTRBookText], recentBudget: Int, searchBudget: Int)
        -> String
    {
        let terms = Array(
            Set(
                rawTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { $0.count >= 3 })
        ).sorted()

        // Where the open book's recent window starts.
        var recentStart: (book: Int, passage: Int)?
        if let currentIndex = texts.lastIndex(where: \.isCurrentBook) {
            var used = 0
            var start = texts[currentIndex].passages.endIndex
            for index in texts[currentIndex].passages.indices.reversed() {
                let length = texts[currentIndex].passages[index].text.count
                if used + length > recentBudget, start < texts[currentIndex].passages.endIndex { break }
                used += length
                start = index
            }
            recentStart = (currentIndex, start)
        }

        func isRecent(_ book: Int, _ passage: Int) -> Bool {
            guard let recentStart else { return false }
            return book == recentStart.book && passage >= recentStart.passage
        }

        // Score everything outside the recent window.
        struct Hit {
            var book: Int
            var passage: Int
            var score: Int
        }
        var hits: [Hit] = []
        if !terms.isEmpty {
            for (bookIndex, text) in texts.enumerated() {
                for (passageIndex, passage) in text.passages.enumerated() where !isRecent(bookIndex, passageIndex) {
                    let lower = passage.text.lowercased()
                    var score = 0
                    for term in terms {
                        let count = occurrences(of: term, in: lower)
                        // Multi-word terms are more specific than single words.
                        score += count * term.split(separator: " ").count
                    }
                    if score > 0 { hits.append(Hit(book: bookIndex, passage: passageIndex, score: score)) }
                }
            }
        }
        // Best first; among equals, later text (closer to the reader) first.
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.book != rhs.book { return lhs.book > rhs.book }
            return lhs.passage > rhs.passage
        }

        var selected: [Int: Set<Int>] = [:]
        var used = 0
        for hit in hits {
            var wanted = [hit.passage]
            if hit.passage > 0, !isRecent(hit.book, hit.passage - 1) { wanted.insert(hit.passage - 1, at: 0) }
            for index in wanted where !(selected[hit.book]?.contains(index) ?? false) {
                let length = texts[hit.book].passages[index].text.count
                guard used + length <= searchBudget else { continue }
                used += length
                selected[hit.book, default: []].insert(index)
            }
            if used >= searchBudget { break }
        }

        var sections: [String] = []
        for (bookIndex, text) in texts.enumerated() {
            var indices = (selected[bookIndex] ?? []).sorted()
            if let recentStart, recentStart.book == bookIndex {
                indices += Array(recentStart.passage..<text.passages.endIndex)
            }
            guard !indices.isEmpty else { continue }
            var lines = [header(for: text)]
            var currentChapter: String?
            var previous: Int?
            for index in indices {
                if let previous, index != previous + 1 { lines.append("[…]") }
                if let recentStart, recentStart.book == bookIndex, index == recentStart.passage {
                    lines.append("[Most recent text before the reader's position:]")
                    currentChapter = nil
                }
                let passage = text.passages[index]
                if passage.chapter != currentChapter {
                    lines.append("--- \(passage.chapter) ---")
                    currentChapter = passage.chapter
                }
                lines.append(passage.text)
                previous = index
            }
            sections.append(lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Case-insensitive whole-word occurrences (`text` already lowercased).
    static func occurrences(of term: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: term, range: searchRange) {
            let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            if beforeOK && afterOK { count += 1 }
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    /// Words worth searching for when the model's plan isn't available:
    /// the reader's selection, plus the question's longer non-filler words.
    static func fallbackTerms(question: String, selectedText: String?) -> [String] {
        var terms: [String] = []
        if let selectedText {
            let cleaned = selectedText.replacingOccurrences(of: "…", with: " ")
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if !cleaned.isEmpty { terms.append(cleaned) }
        }
        let words = question.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        terms += words.filter { $0.count >= 4 && !stopWords.contains($0.lowercased()) }
        return terms
    }

    private static let stopWords: Set<String> = [
        "what", "when", "where", "which", "while", "who's", "whom", "whose", "why's", "that", "this", "these",
        "those", "there", "their", "they", "them", "then", "than", "have", "been", "does", "doing", "done",
        "about", "would", "could", "should", "with", "from", "into", "just", "like", "said", "says", "tell",
        "explain", "mean", "means", "happen", "happened", "happening", "going", "were", "will", "your",
        "book", "chapter", "story", "character", "characters", "again", "remind", "know", "think",
    ]
}
