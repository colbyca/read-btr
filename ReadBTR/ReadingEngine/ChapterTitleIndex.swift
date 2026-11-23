import Foundation
@preconcurrency import ReadiumShared

/// Maps each resource in a publication's reading order to the chapter
/// title the reader should see for it in the reading-mode toolbar.
///
/// "Chapter" == Readium resource for MVP (design-roadmap.md §10), so the
/// title for a resource is its first table-of-contents entry. A resource
/// with no TOC entry of its own (a chapter split across several files)
/// inherits the title of the nearest TOC'd resource before it. Resources
/// before the first TOC entry (cover, title page) have no title.
struct ChapterTitleIndex: Equatable {
    private let titlesByHref: [String: String]

    /// `readingOrderHrefs` in reading order; `tocEntries` in TOC order
    /// (already flattened). Hrefs are compared without their fragment.
    init(readingOrderHrefs: [String], tocEntries: [(href: String, title: String)]) {
        var firstTitleByHref: [String: String] = [:]
        for entry in tocEntries {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let href = Self.stripFragment(entry.href)
            if firstTitleByHref[href] == nil {
                firstTitleByHref[href] = title
            }
        }

        var titles: [String: String] = [:]
        var lastTitle: String?
        for href in readingOrderHrefs.map(Self.stripFragment) {
            if let title = firstTitleByHref[href] {
                lastTitle = title
            }
            if let lastTitle {
                titles[href] = lastTitle
            }
        }
        // TOC entries pointing outside the reading order still resolve.
        for (href, title) in firstTitleByHref where titles[href] == nil {
            titles[href] = title
        }
        titlesByHref = titles
    }

    func title(forResourceHref href: String) -> String? {
        titlesByHref[Self.stripFragment(href)]
    }

    static func stripFragment(_ href: String) -> String {
        href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
    }
}

extension ChapterTitleIndex {
    /// Builds the index from the publication's own reading order and TOC.
    /// A TOC that fails to load just yields an index with no titles.
    static func make(for publication: Publication) async -> ChapterTitleIndex {
        var entries: [(href: String, title: String)] = []
        if case let .success(toc) = await publication.tableOfContents() {
            entries = flatten(toc)
        }
        return ChapterTitleIndex(
            readingOrderHrefs: publication.readingOrder.map { $0.url().string },
            tocEntries: entries
        )
    }

    private static func flatten(_ links: [ReadiumShared.Link]) -> [(href: String, title: String)] {
        links.flatMap { link -> [(href: String, title: String)] in
            let own: [(href: String, title: String)] = link.title.map { [(href: link.url().string, title: $0)] } ?? []
            return own + flatten(link.children)
        }
    }
}
