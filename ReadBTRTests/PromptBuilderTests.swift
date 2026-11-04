import Foundation
import Testing

@testable import ReadBTR

struct PromptBuilderTests {
    @Test func systemPromptAsksForMarkdownAndForbidsSpoilers() {
        let prompt = PromptBuilder.chatSystemPrompt(currentBookTitle: "Book Two", earlierBookTitles: [])
        #expect(prompt.contains("\"Book Two\""))
        #expect(prompt.contains("Markdown"))
        #expect(prompt.contains("Never reveal"))
        #expect(!prompt.contains("Before it they read"))
    }

    @Test func systemPromptListsEarlierBooksInOrder() {
        let prompt = PromptBuilder.chatSystemPrompt(
            currentBookTitle: "Book Three", earlierBookTitles: ["Book One", "Book Two"])
        #expect(prompt.contains("\"Book One\", \"Book Two\""))
        #expect(prompt.contains("any later book"))
    }

    @Test func chatTurnCarriesExcerptsFocusAndQuestion() {
        let turn = PromptBuilder.chatTurn(
            question: "Who is she?",
            focus: PromptBuilder.ChatFocus(passage: "said the Duchess to Alice", selectedText: "Duchess"),
            excerpts: "=== Book ===\nSome text.")
        #expect(turn.contains("Some text."))
        #expect(turn.contains("said the Duchess to Alice"))
        #expect(turn.contains("\"Duchess\""))
        #expect(turn.hasSuffix("Reader's question: Who is she?"))
    }

    @Test func chatTurnWithoutSelectionOmitsSelectedLine() {
        let turn = PromptBuilder.chatTurn(
            question: "Q", focus: PromptBuilder.ChatFocus(passage: "a b c", selectedText: nil), excerpts: "x")
        #expect(turn.contains("a b c"))
        #expect(!turn.contains("selected these words"))
    }

    @Test func retrievalPlanPromptIncludesQuestionTitlesAndConversation() {
        let prompt = PromptBuilder.retrievalPlanPrompt(
            question: "Why is the Hatter angry?",
            focus: nil,
            recentConversation: [AIChatMessage(role: .user, text: "Who is the Hatter?")],
            bookTitles: ["One", "Two"])
        #expect(prompt.contains("Why is the Hatter angry?"))
        #expect(prompt.contains("\"One\", \"Two\""))
        #expect(prompt.contains("Reader: Who is the Hatter?"))
    }

    @Test func retrievalPlanSchemaDecodesIntoSearchTerms() throws {
        let schema = PromptBuilder.retrievalPlanSchema
        #expect(schema["type"] as? String == "OBJECT")
        let properties = try #require(schema["properties"] as? [String: Any])
        let terms = try #require(properties["searchTerms"] as? [String: Any])
        #expect(terms["type"] as? String == "ARRAY")
    }
}
