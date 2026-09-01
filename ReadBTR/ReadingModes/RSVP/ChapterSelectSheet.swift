import SwiftUI
@preconcurrency import ReadiumShared

/// "A sheet listing `publication.tableOfContents()`, tapping an entry calls
/// `book.updatePosition(from:)` with that chapter's start locator"
/// (design-roadmap.md §6.3).
struct ChapterSelectSheet: View {
    let publication: Publication
    let onSelect: (Locator) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [(depth: Int, link: ReadiumShared.Link)] = []

    var body: some View {
        NavigationStack {
            List(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button {
                    Task {
                        if let locator = await publication.locate(entry.link) {
                            onSelect(locator)
                        }
                        dismiss()
                    }
                } label: {
                    Text(entry.link.title ?? entry.link.href)
                        .padding(.leading, CGFloat(entry.depth) * 16)
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if case let .success(toc) = await publication.tableOfContents() {
                    entries = Self.flatten(toc)
                }
            }
        }
    }

    private static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [(depth: Int, link: ReadiumShared.Link)] {
        links.flatMap { link in
            [(depth, link)] + flatten(link.children, depth: depth + 1)
        }
    }
}
