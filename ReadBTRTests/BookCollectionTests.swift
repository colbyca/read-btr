import Foundation
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
struct BookCollectionTests {
    private static func makeBook(_ title: String, in context: ModelContext) -> Book {
        let book = Book(title: title, relativeFilePath: "Books/\(title).epub", position: ModelsTests.makePosition())
        context.insert(book)
        return book
    }

    @Test func appendKeepsReadingOrderAndIgnoresDuplicates() throws {
        let context = try ModelsTests.makeContext()
        let one = Self.makeBook("One", in: context)
        let two = Self.makeBook("Two", in: context)
        let collection = BookCollection(name: "Series")
        context.insert(collection)

        collection.append(one, in: context)
        collection.append(two, in: context)
        collection.append(one, in: context)

        #expect(collection.orderedBooks.map(\.title) == ["One", "Two"])
        #expect(collection.orderedEntries.map(\.position) == [0, 1])
    }

    @Test func moveMatchesSwiftUIOnMoveSemantics() throws {
        let context = try ModelsTests.makeContext()
        let collection = BookCollection(name: "Series")
        context.insert(collection)
        for title in ["A", "B", "C", "D"] {
            collection.append(Self.makeBook(title, in: context), in: context)
        }

        // Drag "A" to the end (SwiftUI passes destination == count).
        collection.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        #expect(collection.orderedBooks.map(\.title) == ["B", "C", "D", "A"])

        // Drag "D" (index 2) to the top.
        collection.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(collection.orderedBooks.map(\.title) == ["D", "B", "C", "A"])
        #expect(collection.orderedEntries.map(\.position) == [0, 1, 2, 3])
    }

    @Test func removeRenumbersTheRest() throws {
        let context = try ModelsTests.makeContext()
        let collection = BookCollection(name: "Series")
        context.insert(collection)
        let books = ["A", "B", "C"].map { Self.makeBook($0, in: context) }
        books.forEach { collection.append($0, in: context) }

        collection.remove(books[1], in: context)

        #expect(collection.orderedBooks.map(\.title) == ["A", "C"])
        #expect(collection.orderedEntries.map(\.position) == [0, 1])
        #expect(try context.fetch(FetchDescriptor<Book>()).count == 3)
    }

    @Test func deletingACollectionKeepsItsBooks() throws {
        let context = try ModelsTests.makeContext()
        let book = Self.makeBook("A", in: context)
        let collection = BookCollection(name: "Series")
        context.insert(collection)
        collection.append(book, in: context)
        try context.save()

        context.delete(collection)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Book>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CollectionEntry>()).isEmpty)
        #expect(book.collections.isEmpty)
    }

    // MARK: - Spoiler scope

    @Test func earlierBooksAreOnlyThoseBeforeTheBookInReadingOrder() throws {
        let context = try ModelsTests.makeContext()
        let collection = BookCollection(name: "Series")
        context.insert(collection)
        let books = ["One", "Two", "Three", "Four"].map { Self.makeBook($0, in: context) }
        books.forEach { collection.append($0, in: context) }

        #expect(books[0].earlierBooksInCollections.isEmpty)
        #expect(books[2].earlierBooksInCollections.map(\.title) == ["One", "Two"])
        #expect(books[3].earlierBooksInCollections.map(\.title) == ["One", "Two", "Three"])

        // Reordering changes what counts as "earlier".
        collection.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(books[2].earlierBooksInCollections.map(\.title) == ["Four", "One", "Two"])
    }

    @Test func earlierBooksCombineEveryCollectionWithoutDuplicates() throws {
        let context = try ModelsTests.makeContext()
        let main = Self.makeBook("Main", in: context)
        let prequel = Self.makeBook("Prequel", in: context)
        let spinOff = Self.makeBook("Spin-off", in: context)
        let sequel = Self.makeBook("Sequel", in: context)

        let series = BookCollection(name: "A Series")
        let universe = BookCollection(name: "B Universe")
        context.insert(series)
        context.insert(universe)
        [prequel, main, sequel].forEach { series.append($0, in: context) }
        [spinOff, prequel, main].forEach { universe.append($0, in: context) }

        let earlier = main.earlierBooksInCollections.map(\.title)
        #expect(earlier == ["Prequel", "Spin-off"])
        #expect(!earlier.contains("Sequel"))
        #expect(!earlier.contains("Main"))
    }

    @Test func aBookInNoCollectionHasNoEarlierBooks() throws {
        let context = try ModelsTests.makeContext()
        let book = Self.makeBook("Solo", in: context)
        #expect(book.earlierBooksInCollections.isEmpty)
    }
}

/// Settings saved by builds that had the BTR menu (several AI features,
/// including comprehension checks) must keep loading.
struct LegacyAIFeatureFlagTests {
    @Test func oldMenuFeatureKeysDecodeAsTheChat() throws {
        let json = #"""
            [{"key":"chapterSummary","isEnabled":false},{"key":"entityExtraction","isEnabled":true},
             {"key":"comprehensionCheck","isEnabled":true},{"key":"questionAnswering","isEnabled":false}]
            """#
        let flags = try JSONDecoder().decode([AIFeatureFlag].self, from: Data(json.utf8))

        #expect(flags.count == 4)
        #expect(flags.allSatisfy { $0.key == .btrChat })
        // Entity lookup was on, so the chat counts as on.
        #expect(flags.normalized == [AIFeatureFlag(key: .btrChat, isEnabled: true)])
    }

    @Test func comprehensionChecksAloneDoNotTurnTheChatOn() throws {
        let json = #"[{"key":"comprehensionCheck","isEnabled":true}]"#
        let flags = try JSONDecoder().decode([AIFeatureFlag].self, from: Data(json.utf8))

        #expect(flags.normalized.isEmpty)
        #expect(flags.flag(for: .btrChat) == nil)
    }

    @Test func oldPerBookOverridesStillDecode() throws {
        let json = #"""
            {"aiFeatureFlagOverrides":[{"key":"comprehensionCheck","isEnabled":false}]}
            """#
        let override = try JSONDecoder().decode(BookSettingsOverride.self, from: Data(json.utf8))
        // A retired key's override doesn't count as overriding the chat.
        #expect(override.aiFeatureFlagOverrides.flag(for: .btrChat) == nil)
    }

    @Test func encodingNeverWritesALegacyKey() throws {
        let json = #"[{"key":"questionAnswering","isEnabled":true}]"#
        let flags = try JSONDecoder().decode([AIFeatureFlag].self, from: Data(json.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(flags.normalized), as: UTF8.self)
        #expect(encoded.contains("btrChat"))
        #expect(!encoded.contains("questionAnswering"))
    }

    @MainActor
    @Test func settingsStoreNormalizesSavedFlags() throws {
        let context = try ModelsTests.makeContext()
        let json = #"[{"key":"chapterSummary","isEnabled":true},{"key":"comprehensionCheck","isEnabled":false}]"#
        let settings = AppSettings(aiFeatureFlags: try JSONDecoder().decode([AIFeatureFlag].self, from: Data(json.utf8)))
        context.insert(settings)

        let current = AppSettingsStore.current(in: context)
        #expect(current.aiFeatureFlags == [AIFeatureFlag(key: .btrChat, isEnabled: true)])
    }
}
