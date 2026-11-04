import Foundation
@preconcurrency import ReadiumShared
import Testing

@testable import ReadBTR

// MARK: - The passage at the top of the chat

struct BTRContextWordsTests {
    private static func locator(highlight: String?, after: String? = nil, progression: Double? = nil) throws
        -> Locator
    {
        var json: [String: Any] = ["href": "chapter1.xhtml", "type": "application/xhtml+xml"]
        if let progression { json["locations"] = ["progression": progression] }
        var text: [String: Any] = [:]
        if let highlight { text["highlight"] = highlight }
        if let after { text["after"] = after }
        if !text.isEmpty { json["text"] = text }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try Locator(jsonString: String(decoding: data, as: UTF8.self))
    }

    /// A stream of `words` as they occur in `sentence`, each segment's
    /// locator carrying the text after it, the way the real tokenizer's do.
    private static func stream(_ sentence: String, words: [String]? = nil) throws -> WordStream {
        let bareWords = words ?? sentence.split(separator: " ").map(String.init)
        var cursor = sentence.startIndex
        var segments: [TextContentElement.Segment] = []
        for word in bareWords {
            let range = try #require(sentence.range(of: word, range: cursor..<sentence.endIndex))
            cursor = range.upperBound
            let after = String(sentence[range.upperBound...])
            segments.append(TextContentElement.Segment(locator: try locator(highlight: word, after: after), text: word))
        }
        return WordStream(resourceHref: "chapter1.xhtml", words: segments)
    }

    @Test func buildsTenWordsEitherSideOfASingleWord() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        let anchor = stream.words[50].locator
        let words = BTRContextWords.build(around: anchor, in: stream)

        #expect(words.count == 21)
        #expect(words.first?.text == "word40")
        #expect(words.last?.text == "word60")
        #expect(words.filter(\.isAnchor).map(\.text) == ["word50"])
    }

    @Test func clampsAtTheStartOfTheChapter() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        let words = BTRContextWords.build(around: stream.words[3].locator, in: stream)
        #expect(words.first?.text == "word0")
        #expect(words.count == 14)
    }

    @Test func findsAMultiWordSelectionNearestItsProgression() throws {
        let stream = try RSVPPositionResolverTests.makeStream(wordCount: 100)
        // A selection's highlight spans words; progression points near 70.
        let selection = try Self.locator(highlight: "word70 word71 word72", progression: 0.69)

        let range = BTRContextWords.anchorRange(for: selection, in: stream)
        #expect(range == 70...72)

        let words = BTRContextWords.build(around: selection, in: stream)
        #expect(words.count == 23)
        #expect(words.filter(\.isAnchor).map(\.text) == ["word70", "word71", "word72"])
    }

    @Test func prefersTheOccurrenceClosestToTheSelection() throws {
        let stream = try Self.stream("the cat sat and the cat ran and the cat hid")
        let selection = try Self.locator(highlight: "the cat", progression: 0.75)
        #expect(BTRContextWords.anchorRange(for: selection, in: stream) == 8...9)
    }

    @Test func punctuationIsPutBackAroundWords() throws {
        let stream = try Self.stream(
            "said Alice, “Oh dear!” and ran.", words: ["said", "Alice", "Oh", "dear", "and", "ran"])
        let texts = BTRContextWords.displayTexts(for: stream.words)
        #expect(texts == ["said", "Alice,", "“Oh", "dear!”", "and", "ran."])
    }

    @Test func focusJoinsSelectedWordsAndMarksGaps() {
        let words = ["a", "b", "c", "d"].enumerated().map { BTRContextWord(id: $0, text: $1, isAnchor: false) }
        let focus = BTRContextWords.focus(for: words, selected: [0, 1, 3])
        #expect(focus?.passage == "a b c d")
        #expect(focus?.selectedText == "a b … d")
        #expect(BTRContextWords.focus(for: words, selected: [])?.selectedText == nil)
    }
}

// MARK: - The context agent's retrieval

struct BTRChatContextAgentTests {
    private static func book(_ title: String, current: Bool, _ passages: [(String, String)]) -> BTRBookText {
        BTRBookText(
            bookID: UUID(), title: title, isCurrentBook: current,
            passages: passages.map { BTRTextPassage(chapter: $0.0, text: $0.1) })
    }

    @Test func fullTextKeepsBooksInOrderWithHeaders() throws {
        let texts = [
            Self.book("One", current: false, [("Ch 1", "First book text.")]),
            Self.book("Two", current: true, [("Ch 1", "Second book text.")]),
        ]
        let excerpts = BTRChatContextAgent.formatFullText(texts)
        let one = try #require(excerpts.range(of: "First book text."))
        let two = try #require(excerpts.range(of: "Second book text."))
        #expect(one.lowerBound < two.lowerBound)
        #expect(excerpts.contains("=== One (an earlier book the reader has finished) ==="))
        #expect(excerpts.contains("=== Two (current book, from the start up to the reader's position) ==="))
        #expect(excerpts.contains("--- Ch 1 ---"))
    }

    @Test func retrievalFindsMatchesInEarlierBooksAndKeepsRecentText() {
        let filler = String(repeating: "filler ", count: 30)
        let texts = [
            Self.book(
                "One", current: false,
                [("Ch 1", "The Jabberwock appears in the woods."), ("Ch 2", filler), ("Ch 3", filler)]),
            Self.book(
                "Two", current: true,
                [("Ch 1", filler), ("Ch 2", filler), ("Ch 3", "Alice reached the garden at last.")]),
        ]
        let excerpts = BTRChatContextAgent.retrieve(
            terms: ["Jabberwock"], from: texts, recentBudget: 40, searchBudget: 1000)

        #expect(excerpts.contains("The Jabberwock appears in the woods."))
        #expect(excerpts.contains("Alice reached the garden at last."))
        #expect(excerpts.contains("[Most recent text before the reader's position:]"))
        // Paragraphs that match nothing, outside the recent window, stay out.
        #expect(!excerpts.contains("filler"))
    }

    @Test func retrievalRespectsTheSearchBudget() {
        let passages = (0..<50).map { ("Ch", "dodo number \($0) " + String(repeating: "x", count: 100)) }
        let texts = [Self.book("One", current: false, passages), Self.book("Two", current: true, [("Ch", "Now.")])]
        let excerpts = BTRChatContextAgent.retrieve(terms: ["dodo"], from: texts, recentBudget: 100, searchBudget: 500)
        let hits = excerpts.components(separatedBy: "dodo number").count - 1
        #expect(hits > 0)
        #expect(hits <= 5)
    }

    @Test func occurrencesCountsWholeWordsOnly() {
        #expect(BTRChatContextAgent.occurrences(of: "cat", in: "the cat and the catalogue, cat.") == 2)
        #expect(BTRChatContextAgent.occurrences(of: "mad hatter", in: "the mad hatter is mad") == 1)
    }

    @Test func fallbackTermsUseSelectionAndKeyWords() {
        let terms = BTRChatContextAgent.fallbackTerms(
            question: "Why is the Duchess so angry with her cook?", selectedText: "the Duchess …")
        #expect(terms.first == "the Duchess")
        #expect(terms.contains("Duchess"))
        #expect(terms.contains("angry"))
        #expect(!terms.contains("with"))
    }

    @MainActor
    @Test func agentSendsEverythingWhenItFits() async throws {
        let provider = BTRChatViewModelTests.MockAIProvider()
        let agent = BTRChatContextAgent(sources: [
            .init(bookID: UUID(), title: "One", isCurrentBook: false, load: { [BTRTextPassage(chapter: "C", text: "Earlier.")] }),
            .init(bookID: UUID(), title: "Two", isCurrentBook: true, load: { [BTRTextPassage(chapter: "C", text: "Now.")] }),
        ])
        var statuses: [String] = []
        let context = await agent.gatherContext(
            question: "Q", focus: nil, recentConversation: [], provider: provider, onStatus: { statuses.append($0) })

        #expect(context.usedSearch == false)
        #expect(context.excerpts.contains("Earlier."))
        #expect(context.excerpts.contains("Now."))
        #expect(provider.promptsReceived.isEmpty)
        #expect(statuses.contains("Reading “One”…"))
    }

    @MainActor
    @Test func agentReportsEarlierBooksItCouldNotOpen() async throws {
        let agent = BTRChatContextAgent(sources: [
            .init(bookID: UUID(), title: "Missing", isCurrentBook: false, load: { nil }),
            .init(bookID: UUID(), title: "Two", isCurrentBook: true, load: { [BTRTextPassage(chapter: "C", text: "Now.")] }),
        ])
        let context = await agent.gatherContext(
            question: "Q", focus: nil, recentConversation: [], provider: BTRChatViewModelTests.MockAIProvider(),
            onStatus: { _ in })
        #expect(context.unavailableTitles == ["Missing"])
        #expect(!context.excerpts.contains("Missing"))
    }
}
