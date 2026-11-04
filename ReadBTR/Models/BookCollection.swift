import Foundation
import SwiftData

/// A named, ordered group of books — a series, or any set the reader wants
/// read in order (design-roadmap.md §2.12). The order matters beyond
/// display: the BTR chat treats books earlier in a collection as fully
/// read, and never looks at books after the current one, so the reader
/// can ask about a series without spoilers (§6.6.3).
///
/// A book can belong to several collections, and appears in the library on
/// its own either way. Membership and order live on `CollectionEntry`
/// rows, because SwiftData doesn't keep the order of a to-many relationship.
@Model
final class BookCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CollectionEntry.collection)
    var entries: [CollectionEntry] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// One book's place in one collection. Deleting either the book or the
/// collection deletes the entry (cascade on both sides).
@Model
final class CollectionEntry {
    /// 0-based reading order within the collection. Kept dense
    /// (0, 1, 2, …) by `BookCollection`'s mutating helpers.
    var position: Int
    var collection: BookCollection?
    var book: Book?

    init(position: Int, collection: BookCollection? = nil, book: Book? = nil) {
        self.position = position
        self.collection = collection
        self.book = book
    }
}

extension BookCollection {
    /// The collection's books in reading order. Entries whose book was
    /// deleted out from under them are skipped.
    var orderedBooks: [Book] {
        orderedEntries.compactMap(\.book)
    }

    var orderedEntries: [CollectionEntry] {
        entries.sorted { $0.position < $1.position }
    }

    func contains(_ book: Book) -> Bool {
        entries.contains { $0.book?.id == book.id }
    }

    /// Appends `book` to the end of the reading order. Does nothing if it's
    /// already in the collection.
    func append(_ book: Book, in context: ModelContext) {
        guard !contains(book) else { return }
        let entry = CollectionEntry(position: (entries.map(\.position).max() ?? -1) + 1)
        context.insert(entry)
        entry.collection = self
        entry.book = book
    }

    func remove(_ book: Book, in context: ModelContext) {
        for entry in entries where entry.book?.id == book.id {
            entries.removeAll { $0 === entry }
            context.delete(entry)
        }
        renumber(orderedEntries)
    }

    /// Mirrors SwiftUI's `onMove`: moves the books at `source` (indices
    /// into `orderedBooks`) to before `destination`.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = orderedEntries.filter { $0.book != nil }
        let moving = source.sorted().map { ordered[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            ordered.remove(at: index)
        }
        ordered.insert(contentsOf: moving, at: max(0, min(insertAt, ordered.count)))
        renumber(ordered)
    }

    private func renumber(_ ordered: [CollectionEntry]) {
        for (index, entry) in ordered.enumerated() where entry.position != index {
            entry.position = index
        }
    }
}

extension Book {
    /// Collections this book belongs to, by name.
    var collections: [BookCollection] {
        collectionEntries.compactMap(\.collection).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Every book the BTR chat may read in full when asked about this one:
    /// books that come *before* it in any collection it belongs to, in
    /// reading order. Books after it are never included (no spoilers), and
    /// the book itself isn't either — the chat only reads it up to the
    /// reader's position.
    var earlierBooksInCollections: [Book] {
        var seen: Set<UUID> = [id]
        var result: [Book] = []
        for collection in collections {
            let ordered = collection.orderedBooks
            guard let ownIndex = ordered.firstIndex(where: { $0.id == id }) else { continue }
            for earlier in ordered[..<ownIndex] where seen.insert(earlier.id).inserted {
                result.append(earlier)
            }
        }
        return result
    }
}
