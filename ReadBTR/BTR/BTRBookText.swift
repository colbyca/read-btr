import Foundation
@preconcurrency import ReadiumShared

/// One paragraph-level piece of book text, labelled with its chapter.
struct BTRTextPassage: Equatable, Sendable {
    var chapter: String
    var text: String
}

/// Everything the BTR chat is allowed to read from one book: all of it for
/// a book earlier in a collection, or the start up to the reader's
/// position for the book they have open.
struct BTRBookText: Equatable, Sendable {
    var bookID: UUID
    var title: String
    /// True for the book the reader has open (read only up to their
    /// position); false for an earlier, finished book in a collection.
    var isCurrentBook: Bool
    var passages: [BTRTextPassage]

    var characterCount: Int { passages.reduce(0) { $0 + $1.text.count } }
}

/// Pulls a book's text out of its publication, paragraph by paragraph, in
/// reading order. Built on `BTRChapterTextExtractor.textPieces`, the same
/// per-resource walk the rest of BTR uses, so the spoiler cut-off works
/// the same way everywhere: nothing past the reader's own position.
enum BTRBookTextExtractor {
    /// - Parameter locator: Stop at this position (the reader's place in
    ///   the book they have open). nil reads the whole book.
    static func passages(of publication: Publication, upTo locator: Locator?) async -> [BTRTextPassage] {
        let hrefs = publication.readingOrder.map { $0.url().string }
        let chapterTitles = await chapterTitlesByHref(in: publication)

        let readableHrefs: ArraySlice<String>
        if let locator {
            guard let cutoffIndex = hrefs.firstIndex(of: locator.href.string) else { return [] }
            readableHrefs = hrefs[...cutoffIndex]
        } else {
            readableHrefs = hrefs[...]
        }

        var passages: [BTRTextPassage] = []
        var lastTitle = ""
        for (offset, href) in readableHrefs.enumerated() {
            let isCutoffResource = locator != nil && href == locator?.href.string
            let pieces = await BTRChapterTextExtractor.textPieces(
                ofResource: href, upToProgression: isCutoffResource ? locator?.locations.progression : nil,
                in: publication)
            guard !pieces.isEmpty else { continue }
            // Resources missing from the table of contents usually continue
            // the chapter before them.
            let title = chapterTitles[href] ?? (lastTitle.isEmpty ? "Section \(offset + 1)" : lastTitle)
            lastTitle = title
            passages += pieces.map { BTRTextPassage(chapter: title, text: $0) }
        }
        return passages
    }

    private static func chapterTitlesByHref(in publication: Publication) async -> [String: String] {
        guard case .success(let toc) = await publication.tableOfContents() else { return [:] }
        var titles: [String: String] = [:]
        func visit(_ links: [ReadiumShared.Link]) {
            for link in links {
                let href = link.url().string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                if let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                    titles[href] == nil
                {
                    titles[href] = title
                }
                visit(link.children)
            }
        }
        visit(toc)
        return titles
    }
}

/// Keeps the full text of finished books in memory between chat sessions,
/// since an earlier book's readable text never changes and extracting a
/// whole book takes a moment. The open book isn't cached: its readable
/// text depends on the reader's position.
@MainActor
final class BTRBookTextCache {
    static let shared = BTRBookTextCache()

    private var fullTexts: [UUID: [BTRTextPassage]] = [:]
    private var order: [UUID] = []
    private let capacity = 8

    func fullText(for bookID: UUID) -> [BTRTextPassage]? {
        fullTexts[bookID]
    }

    func store(_ passages: [BTRTextPassage], for bookID: UUID) {
        fullTexts[bookID] = passages
        order.removeAll { $0 == bookID }
        order.append(bookID)
        while order.count > capacity {
            fullTexts[order.removeFirst()] = nil
        }
    }
}
