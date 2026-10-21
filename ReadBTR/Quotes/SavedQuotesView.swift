import SwiftData
import SwiftUI

/// Every quote the reader has saved, from any reading mode, grouped by
/// book with the most recently quoted book first. Reached from the
/// library's toolbar.
struct SavedQuotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedQuote.createdAt, order: .reverse) private var quotes: [SavedQuote]

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if quotes.isEmpty {
                    ContentUnavailableView(
                        "No Saved Quotes",
                        systemImage: "quote.opening",
                        description: Text("Select a passage while reading and tap Save Quote to keep it here.")
                    )
                    .accessibilityIdentifier("saved-quotes-empty")
                } else if sections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    quoteList
                }
            }
            .navigationTitle("Saved Quotes")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search quotes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("saved-quotes-done")
                }
            }
        }
    }

    private var quoteList: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.quotes) { quote in
                        SavedQuoteRow(quote: quote)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(quote)
                                }
                            }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = quote.text
                                }
                                ShareLink(item: SavedQuoteSections.shareText(for: quote))
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(quote)
                                }
                            }
                    }
                }
            }
        }
        .accessibilityIdentifier("saved-quotes-list")
    }

    private var sections: [SavedQuoteSections.Section] {
        SavedQuoteSections.make(from: quotes, matching: searchText)
    }

    private func delete(_ quote: SavedQuote) {
        modelContext.delete(quote)
        try? modelContext.save()
    }
}

private struct SavedQuoteRow: View {
    let quote: SavedQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("“\(quote.text)”")
                .font(.system(.body, design: .serif))
                .italic()
                .textSelection(.enabled)
            Text(quote.createdAt, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("saved-quote-\(quote.id)")
    }
}

/// Grouping, filtering, and share formatting for `SavedQuotesView`, kept
/// separate from the view so it can be unit tested.
enum SavedQuoteSections {
    struct Section: Identifiable {
        let id: String
        let title: String
        let quotes: [SavedQuote]
    }

    /// Groups `quotes` by book, keeping their incoming order within each
    /// group and ordering groups by their first (newest, given the view's
    /// sort) quote. A search matches quote text, book title, or author.
    static func make(from quotes: [SavedQuote], matching searchText: String = "") -> [Section] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? quotes : quotes.filter { quote in
            quote.text.localizedCaseInsensitiveContains(query)
                || (quote.book?.title.localizedCaseInsensitiveContains(query) ?? false)
                || (quote.book?.author?.localizedCaseInsensitiveContains(query) ?? false)
        }

        var order: [String] = []
        var titles: [String: String] = [:]
        var grouped: [String: [SavedQuote]] = [:]
        for quote in filtered {
            let key = quote.book?.id.uuidString ?? "no-book"
            if grouped[key] == nil {
                order.append(key)
                titles[key] = quote.book?.title ?? "Unknown Book"
            }
            grouped[key, default: []].append(quote)
        }
        return order.map { Section(id: $0, title: titles[$0] ?? "", quotes: grouped[$0] ?? []) }
    }

    static func shareText(for quote: SavedQuote) -> String {
        var attribution = quote.book?.title ?? ""
        if let author = quote.book?.author, !author.isEmpty {
            attribution += attribution.isEmpty ? author : ", \(author)"
        }
        return attribution.isEmpty ? "“\(quote.text)”" : "“\(quote.text)”\n— \(attribution)"
    }
}
