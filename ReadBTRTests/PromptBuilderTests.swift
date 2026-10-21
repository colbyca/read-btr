import Foundation
import Testing

@testable import ReadBTR

struct PromptBuilderTests {
    @Test func entityExtractionPromptEmbedsTitleAndContext() {
        let prompt = PromptBuilder.entityExtractionPrompt(
            bookTitle: "Alice in Wonderland", contextText: "The White Rabbit ran past.")
        #expect(prompt.contains("Alice in Wonderland"))
        #expect(prompt.contains("The White Rabbit ran past."))
    }

    @Test func entityExtractionSchemaShapeMatchesTheDesignedOutput() throws {
        let schema = PromptBuilder.entityExtractionSchema
        #expect(schema["type"] as? String == "OBJECT")

        let properties = try #require(schema["properties"] as? [String: Any])
        let entities = try #require(properties["entities"] as? [String: Any])
        #expect(entities["type"] as? String == "ARRAY")

        let items = try #require(entities["items"] as? [String: Any])
        #expect(items["type"] as? String == "OBJECT")

        let itemProperties = try #require(items["properties"] as? [String: Any])
        #expect(itemProperties["name"] != nil)
        #expect(itemProperties["kind"] != nil)

        let required = try #require(items["required"] as? [String])
        #expect(Set(required) == ["name", "kind"])

        // Round-trips through JSONSerialization cleanly — this is exactly
        // how GeminiProvider embeds it into the request body, so a schema
        // that can't serialize would fail silently there instead.
        #expect(JSONSerialization.isValidJSONObject(schema))
    }

    @Test func entitySummaryPromptEmbedsAllInputs() {
        let prompt = PromptBuilder.entitySummaryPrompt(
            bookTitle: "Alice in Wonderland",
            entityName: "White Rabbit",
            kind: .character,
            snippets: "The White Rabbit checked his pocket watch."
        )
        #expect(prompt.contains("Alice in Wonderland"))
        #expect(prompt.contains("White Rabbit"))
        #expect(prompt.contains("The White Rabbit checked his pocket watch."))
    }

    @Test func chapterSummaryPromptEmbedsTitleAndText() {
        let prompt = PromptBuilder.chapterSummaryPrompt(
            bookTitle: "Alice in Wonderland", chapterText: "Alice fell down the rabbit hole.")
        #expect(prompt.contains("Alice in Wonderland"))
        #expect(prompt.contains("Alice fell down the rabbit hole."))
    }

    // MARK: - Comprehension check

    @Test func comprehensionCheckPromptEmbedsTitleTextAndCount() {
        let prompt = PromptBuilder.comprehensionCheckPrompt(
            bookTitle: "Alice in Wonderland", chapterText: "Alice fell down the hole.", questionCount: 5)
        #expect(prompt.contains("Alice in Wonderland"))
        #expect(prompt.contains("Alice fell down the hole."))
        #expect(prompt.contains("Write 5 multiple-choice questions"))
    }

    @Test func comprehensionCheckSchemaDecodesIntoQuestions() throws {
        let schema = PromptBuilder.comprehensionCheckSchema
        let properties = try #require(schema["properties"] as? [String: Any])
        let questions = try #require(properties["questions"] as? [String: Any])
        #expect(questions["type"] as? String == "ARRAY")
        let items = try #require(questions["items"] as? [String: Any])
        let required = try #require(items["required"] as? [String])
        #expect(Set(required) == ["question", "choices", "correctChoiceIndex", "explanation"])

        // The model's JSON (without a selected answer) decodes cleanly.
        let json = #"{"question":"Q?","choices":["A","B"],"correctChoiceIndex":1,"explanation":"B."}"#
        let decoded = try JSONDecoder().decode(ComprehensionQuestion.self, from: Data(json.utf8))
        #expect(decoded.isWellFormed)
        #expect(decoded.selectedChoiceIndex == nil)
    }

    // MARK: - Q&A

    @Test func questionAnsweringPromptEmbedsTextAndQuestion() {
        let prompt = PromptBuilder.questionAnsweringPrompt(
            bookTitle: "Alice in Wonderland", textSoFar: "The Rabbit took a watch out of its pocket.",
            textWasTruncated: false, history: [], question: "What did the Rabbit carry?")
        #expect(prompt.contains("Alice in Wonderland"))
        #expect(prompt.contains("The Rabbit took a watch out of its pocket."))
        #expect(prompt.contains("What did the Rabbit carry?"))
        #expect(!prompt.contains("Earlier in this conversation"))
        #expect(!prompt.contains("earlier text was left out"))
    }

    @Test func questionAnsweringPromptIncludesRecentHistoryAndTruncationNote() {
        let history = (1...6).map { PromptBuilder.QAHistoryItem(question: "Q\($0)?", answer: "A\($0).") }
        let prompt = PromptBuilder.questionAnsweringPrompt(
            bookTitle: "Alice", textSoFar: "Text.", textWasTruncated: true, history: history, question: "Next?")
        #expect(prompt.contains("earlier text was left out"))
        #expect(prompt.contains("Earlier in this conversation"))
        // Only the most recent `maxQAHistoryItems` exchanges are sent.
        #expect(!prompt.contains("Q2?"))
        #expect(prompt.contains("Q3?"))
        #expect(prompt.contains("A6."))
    }
}
