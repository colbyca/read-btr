import Foundation
@preconcurrency import ReadiumShared

/// Gathers the context an entity's second-stage BTR summary call is grounded
/// in (design-roadmap.md §6.6.3 step 2): walk `publication.readingOrder`
/// from the very start up to and including the resource the reader is
/// currently on, and collect the (paragraph/sentence-level) text of every
/// element that mentions the entity's name.
///
/// BTR-specific business logic, not generic reading-engine machinery — this
/// is the "only text the reader has already reached" spoiler-avoidance rule
/// (dev.md §3) applied to a name search, not a reusable position-resolution
/// primitive the way `ReadingEngine/` types are.
enum BTREntityContextGatherer {
    /// Caps how many matched elements get sent to the AI provider — bounds
    /// prompt size for a book that mentions a common name (e.g. "Alice")
    /// dozens of times. Not specified in the design doc; a judgment call.
    static let maxSnippets = 8

    /// Caps each individual snippet's own length, in words — a safety net
    /// against one pathologically long paragraph/sentence dominating the
    /// prompt; real prose rarely approaches this.
    static let maxWordsPerSnippet = 150

    static func gatherSnippets(
        forEntityNamed name: String, upThroughResourceHref resourceHref: String, in publication: Publication
    ) async -> String {
        let hrefs = publication.readingOrder.map { $0.url().string }
        guard let cutoffIndex = hrefs.firstIndex(of: resourceHref) else { return "" }
        let lowerName = name.lowercased()
        guard !lowerName.isEmpty else { return "" }

        var snippets: [String] = []
        for href in hrefs[...cutoffIndex] {
            guard snippets.count < maxSnippets else { break }
            guard
                let link = publication.readingOrder.first(where: { $0.url().string == href }),
                let startLocator = await publication.locate(link),
                let content = publication.content(from: startLocator)
            else { continue }

            for await element in content.sequence() {
                guard element.locator.href.string == href else {
                    // Crossed into the next resource — this one is done.
                    break
                }
                guard snippets.count < maxSnippets else { break }
                guard
                    let textElement = element as? TextContentElement,
                    let text = textElement.text,
                    text.lowercased().contains(lowerName)
                else { continue }
                snippets.append(truncated(text))
            }
        }
        return snippets.joined(separator: "\n\n")
    }

    private static func truncated(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWordsPerSnippet else { return text }
        return words.prefix(maxWordsPerSnippet).joined(separator: " ") + "…"
    }
}
