import Foundation

/// Every prompt string and JSON schema the BTR menu's AI calls use
/// (design-roadmap.md §6.6.3/§6.6.4) — kept together, and in `AI/` rather
/// than `BTR/`, per the module-layout doc's own "AI/ — AIProvider protocol,
/// GeminiProvider, prompt builders" line. Plain string/dict builders, no
/// state — easy to unit test without a network call or an `AIProvider` at
/// all.
enum PromptBuilder {
    // MARK: - Entity extraction (§6.6.3 step 1)

    static func entityExtractionPrompt(bookTitle: String, contextText: String) -> String {
        """
        You are analyzing a short excerpt from the book "\(bookTitle)" to identify \
        named characters and locations mentioned in it.

        Excerpt:
        \"\"\"
        \(contextText)
        \"\"\"

        List every distinct named character or location mentioned in the excerpt \
        above. Use each entity's most complete name as it appears in the text. Do \
        not invent entities that aren't in the excerpt.
        """
    }

    /// Mirrors Gemini's `responseSchema` request field (design-roadmap.md
    /// §2.8) — a Gemini `Schema` object (uppercase `type` enum values:
    /// `OBJECT`/`ARRAY`/`STRING`), not generic JSON Schema. Shaped to
    /// decode directly into `{"entities": [{"name", "kind"}]}`
    /// (§6.6.3).
    /// A computed property rather than a stored `static let` — `[String:
    /// Any]` isn't `Sendable`, so a stored global constant of that type
    /// trips Swift 6 strict-concurrency's shared-mutable-state check even
    /// though this never actually mutates; a fresh dictionary built on each
    /// access sidesteps that without reaching for `nonisolated(unsafe)`.
    static var entityExtractionSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "entities": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "name": ["type": "STRING"],
                            "kind": ["type": "STRING", "enum": ["character", "location"]],
                        ],
                        "required": ["name", "kind"],
                    ],
                ]
            ],
            "required": ["entities"],
        ]
    }

    // MARK: - Entity summary (§6.6.3 step 2)

    static func entitySummaryPrompt(
        bookTitle: String, entityName: String, kind: EntityKind, snippets: String
    ) -> String {
        let kindDescription = kind == .character ? "character" : "location"
        return """
            You are summarizing the \(kindDescription) "\(entityName)" from the book \
            "\(bookTitle)", based only on the excerpts below — all of them come from \
            parts of the book the reader has already reached, so nothing past this \
            point should be referenced or hinted at.

            Excerpts mentioning "\(entityName)":
            \"\"\"
            \(snippets)
            \"\"\"

            Write a concise (2-4 sentence) summary of who/what "\(entityName)" is and \
            what's happened with them so far, based only on the excerpts above. Plain \
            prose, no headings or markdown.
            """
    }

    // MARK: - Chapter summary (§6.6.4)

    static func chapterSummaryPrompt(bookTitle: String, chapterText: String) -> String {
        """
        You are summarizing what has happened so far in the current chapter of the \
        book "\(bookTitle)", for a reader who has read up to this point and no \
        further.

        Chapter text so far:
        \"\"\"
        \(chapterText)
        \"\"\"

        Write a concise summary (3-6 sentences) of what has happened in this chapter \
        so far, based only on the text above. Plain prose, no headings or markdown.
        """
    }
}
