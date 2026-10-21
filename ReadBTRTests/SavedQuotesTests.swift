import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing
@testable import ReadBTR

// MARK: - Shared helpers

enum SavedQuotesTestSupport {
    static func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self, ComprehensionCheck.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    static func makeTempStorage() throws -> (storage: BookFileStorage, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedQuotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = BookFileStorage(baseDirectoryOverride: tempDir)
        return (storage, { try? FileManager.default.removeItem(at: tempDir) })
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/alice.epub")
    }

    static func makeLocator(highlight: String? = nil, after: String? = nil) throws -> Locator {
        var json: [String: Any] = ["href": "chapter1.xhtml", "type": "application/xhtml+xml"]
        var text: [String: Any] = [:]
        if let highlight { text["highlight"] = highlight }
        if let after { text["after"] = after }
        if !text.isEmpty { json["text"] = text }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try Locator(jsonString: String(data: data, encoding: .utf8)!)
    }

    static func makeBook(title: String = "Alice", author: String? = "Lewis Carroll") -> Book {
        Book(
            title: title,
            author: author,
            relativeFilePath: "\(UUID().uuidString).epub",
            position: BookPosition(locatorJSON: "{}", resourceHref: "chapter1.xhtml", updatedAt: .now)
        )
    }

    /// Builds a stream from (word, after) pairs, the shape the real word
    /// tokenizer produces: punctuation lives in `after`, not the word.
    static func makeStream(_ words: [(String, String)]) throws -> WordStream {
        let segments = try words.map { word, after in
            TextContentElement.Segment(locator: try makeLocator(highlight: word, after: after), text: word)
        }
        return WordStream(resourceHref: "chapter1.xhtml", words: segments)
    }
}

// MARK: - BookDeleter

@MainActor
struct BookDeleterTests {
    @Test func deleteRemovesTheBookItsQuotesAndItsFiles() async throws {
        let (storage, cleanup) = try SavedQuotesTestSupport.makeTempStorage()
        defer { cleanup() }
        let context = try SavedQuotesTestSupport.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: SavedQuotesTestSupport.fixtureURL, into: context)
        try context.save()

        let bookURL = try storage.absoluteURL(forRelativePath: book.relativeFilePath)
        let coverURL = try book.relativeCoverImagePath.map { try storage.absoluteURL(forRelativePath: $0) }
        #expect(FileManager.default.fileExists(atPath: bookURL.path))

        let locator = try SavedQuotesTestSupport.makeLocator(highlight: "Down the rabbit-hole")
        SavedQuoteWriter.save(text: "Down the rabbit-hole", start: locator, book: book, in: context)
        #expect(try context.fetch(FetchDescriptor<SavedQuote>()).count == 1)

        try BookDeleter(fileStorage: storage).delete(book, from: context)

        #expect(try context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SavedQuote>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bookURL.path))
        if let coverURL {
            #expect(!FileManager.default.fileExists(atPath: coverURL.path))
        }
    }

    @Test func deleteLeavesOtherBooksAlone() throws {
        let (storage, cleanup) = try SavedQuotesTestSupport.makeTempStorage()
        defer { cleanup() }
        let context = try SavedQuotesTestSupport.makeContext()
        let kept = SavedQuotesTestSupport.makeBook(title: "Kept")
        let removed = SavedQuotesTestSupport.makeBook(title: "Removed")
        context.insert(kept)
        context.insert(removed)
        try context.save()

        try BookDeleter(fileStorage: storage).delete(removed, from: context)

        let remaining = try context.fetch(FetchDescriptor<Book>())
        #expect(remaining.map(\.title) == ["Kept"])
    }
}

// MARK: - SavedQuoteWriter

@MainActor
struct SavedQuoteWriterTests {
    @Test func saveCollapsesWhitespaceAndLinksTheBook() throws {
        let context = try SavedQuotesTestSupport.makeContext()
        let book = SavedQuotesTestSupport.makeBook()
        context.insert(book)
        let locator = try SavedQuotesTestSupport.makeLocator(highlight: "x")

        let quote = SavedQuoteWriter.save(text: "  Curiouser\n  and   curiouser!  ", start: locator, book: book, in: context)

        #expect(quote?.text == "Curiouser and curiouser!")
        #expect(quote?.book === book)
        #expect(book.savedQuotes.count == 1)
        #expect(quote?.startLocatorJSON == quote?.endLocatorJSON)
    }

    @Test func saveSkipsBlankText() throws {
        let context = try SavedQuotesTestSupport.makeContext()
        let book = SavedQuotesTestSupport.makeBook()
        context.insert(book)
        let locator = try SavedQuotesTestSupport.makeLocator()

        #expect(SavedQuoteWriter.save(text: " \n\t ", start: locator, book: book, in: context) == nil)
        #expect(try context.fetch(FetchDescriptor<SavedQuote>()).isEmpty)
    }

    @Test func saveStoresSeparateStartAndEndLocators() throws {
        let context = try SavedQuotesTestSupport.makeContext()
        let book = SavedQuotesTestSupport.makeBook()
        context.insert(book)
        let start = try SavedQuotesTestSupport.makeLocator(highlight: "first")
        let end = try SavedQuotesTestSupport.makeLocator(highlight: "last")

        let quote = SavedQuoteWriter.save(text: "first last", start: start, end: end, book: book, in: context)

        #expect(try Locator(jsonString: quote?.startLocatorJSON ?? "").text.highlight == "first")
        #expect(try Locator(jsonString: quote?.endLocatorJSON ?? "").text.highlight == "last")
    }
}

// MARK: - WordStream.sentence(around:)

struct WordStreamSentenceTests {
    static func makeAliceStream() throws -> WordStream {
        // "Alice was tired. 'Oh dear,' said the Rabbit. Down she went!"
        try SavedQuotesTestSupport.makeStream([
            ("Alice", " was tired. "),
            ("was", " tired. 'Oh"),
            ("tired", ". 'Oh dear,'"),
            ("Oh", " dear,' said"),
            ("dear", ",' said the"),
            ("said", " the Rabbit."),
            ("the", " Rabbit. Down"),
            ("Rabbit", ". Down she"),
            ("Down", " she went!"),
            ("she", " went!"),
            ("went", "!"),
        ])
    }

    @Test func findsTheMiddleSentenceWithItsPunctuation() throws {
        let stream = try Self.makeAliceStream()
        let sentence = stream.sentence(around: 5)
        #expect(sentence?.range == 3...7)
        #expect(sentence?.text == "Oh dear,' said the Rabbit.")
    }

    @Test func firstAndLastSentencesStopAtTheStreamEdges() throws {
        let stream = try Self.makeAliceStream()
        #expect(stream.sentence(around: 0)?.text == "Alice was tired.")
        #expect(stream.sentence(around: 10)?.range == 8...10)
        #expect(stream.sentence(around: 10)?.text == "Down she went!")
    }

    @Test func unpunctuatedTextIsCappedByTheRadius() throws {
        let words = (0..<50).map { ("w\($0)", " w\($0 + 1)") }
        let stream = try SavedQuotesTestSupport.makeStream(words)
        let sentence = stream.sentence(around: 25, maxRadius: 5)
        #expect(sentence?.range == 20...30)
    }

    @Test func outOfRangeIndexReturnsNil() throws {
        let stream = try Self.makeAliceStream()
        #expect(stream.sentence(around: 99) == nil)
    }
}

// MARK: - SavedQuoteSections

@MainActor
struct SavedQuoteSectionsTests {
    @Test func groupsByBookInIncomingOrderAndFiltersBySearch() throws {
        let context = try SavedQuotesTestSupport.makeContext()
        let alice = SavedQuotesTestSupport.makeBook(title: "Alice")
        let oz = SavedQuotesTestSupport.makeBook(title: "Oz", author: "L. Frank Baum")
        context.insert(alice)
        context.insert(oz)
        let locator = try SavedQuotesTestSupport.makeLocator()
        let newest = try #require(SavedQuoteWriter.save(text: "There's no place like home.", start: locator, book: oz, in: context))
        let middle = try #require(SavedQuoteWriter.save(text: "Curiouser and curiouser!", start: locator, book: alice, in: context))
        let oldest = try #require(SavedQuoteWriter.save(text: "Follow the yellow brick road.", start: locator, book: oz, in: context))

        let sections = SavedQuoteSections.make(from: [newest, middle, oldest])
        #expect(sections.map(\.title) == ["Oz", "Alice"])
        #expect(sections.first?.quotes.map(\.text) == [newest.text, oldest.text])

        let filtered = SavedQuoteSections.make(from: [newest, middle, oldest], matching: "curiouser")
        #expect(filtered.map(\.title) == ["Alice"])

        let byAuthor = SavedQuoteSections.make(from: [newest, middle, oldest], matching: "baum")
        #expect(byAuthor.map(\.title) == ["Oz"])
    }

    @Test func shareTextIncludesAttribution() throws {
        let context = try SavedQuotesTestSupport.makeContext()
        let book = SavedQuotesTestSupport.makeBook(title: "Alice", author: "Lewis Carroll")
        context.insert(book)
        let quote = try #require(
            SavedQuoteWriter.save(
                text: "We're all mad here.", start: try SavedQuotesTestSupport.makeLocator(), book: book, in: context))

        #expect(SavedQuoteSections.shareText(for: quote) == "“We're all mad here.”\n— Alice, Lewis Carroll")
    }
}
