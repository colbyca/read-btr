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
}
