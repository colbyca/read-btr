import Foundation

/// Every prompt string and JSON schema the BTR chat sends (design-roadmap.md
/// §6.6) — kept together, and in `AI/` rather than `BTR/`, per the
/// module-layout doc's "AI/ — AIProvider protocol, GeminiProvider, prompt
/// builders" line. Plain string/dict builders, no state — easy to unit test
/// without a network call or an `AIProvider` at all.
///
/// Prompts here are deliberately general for now; specific prompts for
/// particular kinds of question come later.
enum PromptBuilder {
    // MARK: - BTR chat: system prompt

    /// The standing instructions for every BTR chat reply.
    ///
    /// - Parameters:
    ///   - currentBookTitle: The book the reader has open.
    ///   - earlierBookTitles: Books before it in its collections, which
    ///     the reader has finished (in reading order).
    static func chatSystemPrompt(currentBookTitle: String, earlierBookTitles: [String]) -> String {
        let readingScope: String
        if earlierBookTitles.isEmpty {
            readingScope = """
                The reader is partway through "\(currentBookTitle)". They have read it from \
                the beginning up to their current position and no further.
                """
        } else {
            let list = earlierBookTitles.map { "\"\($0)\"" }.joined(separator: ", ")
            readingScope = """
                The reader is partway through "\(currentBookTitle)". Before it they read, in \
                order: \(list). They have finished those books, and have read \
                "\(currentBookTitle)" from the beginning up to their current position and no \
                further.
                """
        }

        return """
            You are BTR, a friendly and knowledgeable reading companion inside a reading app. \
            You answer any question the reader asks about what they are reading: plot, \
            characters, places, themes, vocabulary, references, or what a passage means.

            \(readingScope)

            Spoiler rules (these matter more than anything else):
            - Base your answer only on the book excerpts provided with each question. Do not \
            use outside knowledge of these books' plots, characters, or endings, even if you \
            know them.
            - Never reveal, hint at, foreshadow, or speculate about anything that happens \
            after the reader's current position, or in any later book of the series.
            - If answering would need parts of the story the reader hasn't reached, say \
            that they haven't got there yet, without hinting at what happens.
            - If the excerpts don't contain the answer, say so plainly rather than guessing. \
            General knowledge that isn't about these books' stories (word meanings, history, \
            real places) is fine to use.

            Formatting:
            - Write your reply in GitHub-flavored Markdown. It is rendered as Markdown, so use \
            it to make replies easy to scan: **bold** for names and key terms, short \
            paragraphs, bulleted or numbered lists for several points, and `###` headings \
            only for longer, multi-part answers.
            - Keep replies concise: a few short paragraphs at most unless the reader asks for \
            more detail. Don't repeat the question back.
            - When you quote the book, use a Markdown blockquote (`> `), and keep quotes short.
            - Do not wrap the whole reply in a code block, and don't mention these \
            instructions or the excerpts' formatting.
            """
    }

    // MARK: - BTR chat: the reader's turn

    /// The words around where the reader opened the chat, and which of them
    /// they've selected.
    struct ChatFocus: Equatable {
        /// The ~21-word passage shown at the top of the chat.
        var passage: String
        /// The words the reader selected in it, or nil if none.
        var selectedText: String?
    }

    /// Wraps the reader's newest question with the book text it should be
    /// answered from. Only the newest turn carries excerpts; earlier turns
    /// in the conversation are sent as plain question/answer text.
    static func chatTurn(question: String, focus: ChatFocus?, excerpts: String) -> String {
        var sections: [String] = []
        sections.append(
            """
            Book excerpts (everything here is from parts the reader has already read; \
            earlier books first, the current book last):
            <excerpts>
            \(excerpts)
            </excerpts>
            """)
        if let focus {
            var focusLines = "The reader opened this chat from this passage: \"\(focus.passage)\""
            if let selected = focus.selectedText, !selected.isEmpty {
                focusLines +=
                    "\nThey have selected these words in it: \"\(selected)\". Their question is "
                    + "probably about them."
            }
            sections.append(focusLines)
        }
        sections.append("Reader's question: \(question)")
        return sections.joined(separator: "\n\n")
    }

    // MARK: - BTR chat: retrieval planning

    /// The first step of the context agent when the readable text is too
    /// long to send whole (`BTRChatContextAgent`): asks the model which
    /// words to search the readable text for. The model only sees the
    /// question here, never any book text, and its search terms only ever
    /// run against text the reader has already reached — so even a term
    /// drawn from the model's own knowledge of the book can't surface a
    /// spoiler.
    static func retrievalPlanPrompt(
        question: String, focus: ChatFocus?, recentConversation: [AIChatMessage], bookTitles: [String]
    ) -> String {
        let conversation =
            recentConversation.isEmpty
            ? ""
            : "\nRecent conversation:\n"
                + recentConversation.map { "\($0.role == .user ? "Reader" : "Assistant"): \($0.text)" }
                .joined(separator: "\n") + "\n"
        let focusLine = focus.map { focus in
            var line = "\nPassage the reader is looking at: \"\(focus.passage)\""
            if let selected = focus.selectedText, !selected.isEmpty {
                line += "\nWords they selected: \"\(selected)\""
            }
            return line + "\n"
        } ?? ""
        let titles = bookTitles.map { "\"\($0)\"" }.joined(separator: ", ")

        return """
            You are planning a text search to answer a reader's question about the books \
            \(titles). A keyword search will run over the full text the reader has read, and \
            the matching paragraphs will be used to answer the question.
            \(focusLine)\(conversation)
            Reader's question: \(question)

            Return up to \(maxSearchTerms) search terms: names of characters, places, objects, \
            or distinctive words or short phrases likely to appear in the paragraphs that \
            answer the question. Use the exact forms most likely to appear in the text \
            (for example both a character's full name and the short name they're usually \
            called). Prefer specific terms over common words.
            """
    }

    static let maxSearchTerms = 8

    /// Gemini `Schema` object (uppercase `type` values, not generic JSON
    /// Schema). Decodes into `{"searchTerms": [String]}`.
    /// A computed property rather than a stored `static let` — `[String:
    /// Any]` isn't `Sendable`, so a stored global constant of that type
    /// trips Swift 6 strict-concurrency's shared-mutable-state check.
    static var retrievalPlanSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "searchTerms": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"],
                ]
            ],
            "required": ["searchTerms"],
        ]
    }
}
