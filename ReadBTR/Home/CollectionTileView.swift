import SwiftUI

/// A collection's cell in the library grid: its first books' covers fanned
/// behind each other, with the name and book count underneath, so it reads
/// as "a stack of books" next to the single-book cells.
struct CollectionTileView: View {
    let collection: BookCollection

    var body: some View {
        let books = Array(collection.orderedBooks.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.6))
                if books.isEmpty {
                    Image(systemName: "books.vertical")
                        .font(.title)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(books.enumerated().reversed()), id: \.element.id) { offset, book in
                        BookCoverView(book: book)
                            .shadow(radius: 1)
                            .scaleEffect(1 - CGFloat(offset) * 0.08)
                            .offset(x: CGFloat(offset) * 7, y: -CGFloat(offset) * 7)
                    }
                    .padding(10)
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)

            Text(collection.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(countLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.name), collection, \(countLabel)")
    }

    private var countLabel: String {
        let count = collection.orderedBooks.count
        return count == 1 ? "1 book" : "\(count) books"
    }
}
