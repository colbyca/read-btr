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

    // MARK: - Comprehension check (dev.md §3)

    /// How many questions one check asks. dev.md §3 says "N questions";
    /// three keeps a check quick enough to do between chapters.
    static let comprehensionQuestionCount = 3

    static func comprehensionCheckPrompt(
        bookTitle: String, chapterText: String, questionCount: Int = comprehensionQuestionCount
    ) -> String {
        """
        You are writing a short comprehension check for a reader of the book \
        "\(bookTitle)". They have just read the chapter text below, and nothing past it.

        Chapter text:
        \"\"\"
        \(chapterText)
        \"\"\"

        Write \(questionCount) multiple-choice questions that check whether the reader \
        understood this text: what happened, why characters acted as they did, and \
        how events connect. Avoid trivia about exact wording or minor details. Every \
        question must be answerable from the text above alone; do not use any outside \
        knowledge of the book, and never refer to events after this text.

        Give each question exactly 4 answer choices, with one clearly correct choice \
        and plausible wrong ones. Vary which position holds the correct choice. \
        `correctChoiceIndex` is the 0-based index of the correct choice. \
        `explanation` is one or two sentences saying why that choice is correct, \
        based on the text.
        """
    }

    /// Gemini `Schema` object, same conventions as
    /// `entityExtractionSchema`. Decodes into `[ComprehensionQuestion]`
    /// under a top-level `questions` key.
    static var comprehensionCheckSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "questions": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "question": ["type": "STRING"],
                            "choices": ["type": "ARRAY", "items": ["type": "STRING"]],
                            "correctChoiceIndex": ["type": "INTEGER"],
                            "explanation": ["type": "STRING"],
                        ],
                        "required": ["question", "choices", "correctChoiceIndex", "explanation"],
                    ],
                ]
            ],
            "required": ["questions"],
        ]
    }

    // MARK: - Q&A (dev.md §3)

    /// One earlier question and answer in the same Q&A session, passed back
    /// in so follow-up questions ("why did she do that?") make sense.
    struct QAHistoryItem: Equatable {
        var question: String
        var answer: String
    }

    /// How many earlier exchanges get sent along with a new question.
    static let maxQAHistoryItems = 4

    static func questionAnsweringPrompt(
        bookTitle: String,
        textSoFar: String,
        textWasTruncated: Bool,
        history: [QAHistoryItem],
        question: String
    ) -> String {
        let truncationNote =
            textWasTruncated
            ? "The text below is only the most recent part of what the reader has read; earlier text was left out for length.\n\n"
            : ""
        let historyBlock: String
        let recentHistory = history.suffix(maxQAHistoryItems)
        if recentHistory.isEmpty {
            historyBlock = ""
        } else {
            let lines = recentHistory.map { "Reader: \($0.question)\nYou: \($0.answer)" }.joined(separator: "\n\n")
            historyBlock = """

                Earlier in this conversation:
                \"\"\"
                \(lines)
                \"\"\"

                """
        }

        return """
            You are a reading companion answering a question about the book \
            "\(bookTitle)". The reader has read up to the end of the text below and no \
            further.

            \(truncationNote)Text the reader has read so far:
            \"\"\"
            \(textSoFar)
            \"\"\"
            \(historyBlock)
            Reader's question: \(question)

            Rules:
            - Answer using only the text above. Do not use outside knowledge of this \
            book's plot, characters, or ending, even if you know it.
            - Never reveal, hint at, or speculate about anything that happens after \
            the end of the text above. If the question can only be answered by later \
            parts of the book, say that the reader hasn't reached that yet.
            - If the text above doesn't answer the question, say so plainly instead of \
            guessing.
            - Keep the answer short: a few sentences of plain prose, no headings or \
            markdown.
            """
    }
}
