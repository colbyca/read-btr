import SwiftUI

/// One block-level piece of a Markdown document.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A list item. `marker` is nil for bullets, or the item's number.
    case listItem(marker: Int?, depth: Int, text: String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case divider
}

/// A small block-level Markdown parser for BTR chat replies. SwiftUI's
/// `AttributedString(markdown:)` only handles inline syntax (bold, italic,
/// code, links); headings, lists, quotes, code blocks and tables are split
/// out here, and each block's inline text is styled by `AttributedString`.
/// Covers the GitHub-flavored subset a chat reply realistically uses; any
/// unrecognized line is just paragraph text.
enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var codeLines: [String]?
        var tableLines: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushTable() {
            defer { tableLines = [] }
            guard !tableLines.isEmpty else { return }
            let rows = tableLines.map(tableCells)
            // A real table has a |---|---| separator as its second row.
            if rows.count >= 2, rows[1].allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") }) {
                blocks.append(.table(header: rows[0], rows: Array(rows.dropFirst(2))))
            } else {
                blocks.append(.paragraph(tableLines.joined(separator: "\n")))
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if var lines = codeLines {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    lines.append(rawLine)
                    codeLines = lines
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                codeLines = []
                continue
            }
            if line.isEmpty {
                flushAll()
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                flushQuote()
                tableLines.append(line)
                continue
            }
            flushTable()

            if line.hasPrefix(">") {
                flushParagraph()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(heading)
            } else if isDivider(line) {
                flushParagraph()
                blocks.append(.divider)
            } else if let item = listItem(in: rawLine) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        if let codeLines { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(in rawLine: String) -> MarkdownBlock? {
        let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = indent / 2
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ ", "• "] where line.hasPrefix(bullet) {
            return .listItem(marker: nil, depth: depth, text: String(line.dropFirst(bullet.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3, let number = Int(digits) {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: number, depth: depth, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = Substring(line)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) styled by
    /// Foundation; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Renders Markdown with block-level layout — the BTR chat's reply bubble.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker.map { "\($0)." } ?? "•")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tint)
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownParser.inline(cell)).bold()
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownParser.inline(cell))
                            }
                        }
                    }
                }
                .font(.callout)
            }
        case .divider:
            Divider()
        }
    }
}
