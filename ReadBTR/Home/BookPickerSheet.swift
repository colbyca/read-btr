import SwiftData
import SwiftUI

/// Pick several library books, in order. Used to fill a new collection and
/// to add existing books to one. Books are numbered in the order they're
/// tapped, which becomes their order in the collection.
struct BookPickerSheet: View {
    let title: String
    let confirmLabel: String
    /// Books to leave out (already in the collection).
    var excluding: Set<UUID> = []
    let onConfirm: ([Book]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var books: [Book]
    @State private var picked: [Book] = []

    var body: some View {
        NavigationStack {
            List {
                if available.isEmpty {
                    Text("Every book in your library is already here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(available) { book in
                    Button {
                        toggle(book)
                    } label: {
                        BookPickerRow(book: book, number: picked.firstIndex(of: book).map { $0 + 1 })
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pick-book-\(book.id)")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        onConfirm(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("pick-books-confirm")
                }
            }
        }
    }

    private var available: [Book] {
        books.filter { !excluding.contains($0.id) }
    }

    private func toggle(_ book: Book) {
        if let index = picked.firstIndex(of: book) {
            picked.remove(at: index)
        } else {
            picked.append(book)
        }
    }
}

private struct BookPickerRow: View {
    let book: Book
    let number: Int?

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ZStack {
                Circle()
                    .strokeBorder(number == nil ? Color.secondary : Color.accentColor, lineWidth: 1.5)
                    .background(Circle().fill(number == nil ? Color.clear : Color.accentColor))
                if let number {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 26, height: 26)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(number == nil ? [] : .isSelected)
    }
}
