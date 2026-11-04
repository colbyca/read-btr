import Foundation
import Testing

@testable import ReadBTR

struct MarkdownParserTests {
    @Test func parsesHeadingsParagraphsAndLists() {
        let blocks = MarkdownParser.parse(
            """
            ### Who is the Hatter?

            The **Hatter** hosts a tea party.
            He is rude.

            - Rude to Alice
            - Always at tea
              - Since March
            1. First
            2) Second
            """)
        #expect(
            blocks == [
                .heading(level: 3, text: "Who is the Hatter?"),
                .paragraph("The **Hatter** hosts a tea party.\nHe is rude."),
                .listItem(marker: nil, depth: 0, text: "Rude to Alice"),
                .listItem(marker: nil, depth: 0, text: "Always at tea"),
                .listItem(marker: nil, depth: 1, text: "Since March"),
                .listItem(marker: 1, depth: 0, text: "First"),
                .listItem(marker: 2, depth: 0, text: "Second"),
            ])
    }

    @Test func parsesQuotesCodeDividersAndTables() {
        let blocks = MarkdownParser.parse(
            """
            > "Off with her head!"
            > said the Queen.

            ---

            ```
            let x = 1
            ```

            | Name | Role |
            |------|:----:|
            | Alice | Heroine |
            """)
        #expect(
            blocks == [
                .quote("\"Off with her head!\"\nsaid the Queen."),
                .divider,
                .code("let x = 1"),
                .table(header: ["Name", "Role"], rows: [["Alice", "Heroine"]]),
            ])
    }

    @Test func unclosedCodeFenceStillRendersItsContent() {
        #expect(MarkdownParser.parse("```\ncode") == [.code("code")])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(MarkdownParser.parse("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func inlineMarkdownIsStyled() {
        let styled = MarkdownParser.inline("a **bold** word")
        #expect(String(styled.characters) == "a bold word")
    }

    @Test func cleanReplyUnwrapsAWholeReplyCodeFence() {
        #expect(BTRChatViewModel.cleanReply("```markdown\n**Hi**\n```") == "**Hi**")
        #expect(BTRChatViewModel.cleanReply("  plain  ") == "plain")
    }
}
