import Foundation
import SwiftData
import Testing
@testable import ReadBTR

@MainActor
struct BookImporterTests {
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/alice.epub")
    }

    /// A throwaway temp directory per test, so imports never touch the
    /// real simulator/device Application Support storage and never leak
    /// state between test runs.
    static func makeTempStorage() throws -> (storage: BookFileStorage, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = BookFileStorage(baseDirectoryOverride: tempDir)
        return (storage, { try? FileManager.default.removeItem(at: tempDir) })
    }

    static func makeContext() throws -> ModelContext {
        let schema = Schema([Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    @Test func importBookFromRealEPUBProducesCorrectMetadataAndPersistedFile() async throws {
        let (storage, cleanup) = try Self.makeTempStorage()
        defer { cleanup() }
        let context = try Self.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())

        let book = try await importer.importBook(from: Self.fixtureURL, into: context)
        try context.save()

        #expect(book.title == "Alice's Adventures in Wonderland")
        #expect(book.format == .epub)
        #expect(!book.position.locatorJSON.isEmpty)
        #expect(!book.position.resourceHref.isEmpty)

        // This fixture has a real cover image and Readium's default
        // ResourceCoverService picks it up — confirmed empirically, not
        // assumed, so this is a real regression check, not a guess.
        let coverPath = try #require(book.relativeCoverImagePath)
        let coverURL = try storage.absoluteURL(forRelativePath: coverPath)
        let coverAttributes = try FileManager.default.attributesOfItem(atPath: coverURL.path)
        #expect((coverAttributes[.size] as? Int ?? 0) > 0)

        // The copied file actually exists on disk, separately from the
        // fixture — this proves the sandbox copy happened, not just that
        // Readium could open the original fixture path.
        let copiedFileURL = try storage.absoluteURL(forRelativePath: book.relativeFilePath)
        #expect(FileManager.default.fileExists(atPath: copiedFileURL.path))
        #expect(copiedFileURL != Self.fixtureURL)

        // It's inserted and fetchable, not just returned in memory.
        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == book.id)
    }

    @Test func importBookCleansUpCopiedFileWhenParsingFails() async throws {
        let (storage, cleanup) = try Self.makeTempStorage()
        defer { cleanup() }
        let context = try Self.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())

        // A plain text file is not a valid EPUB — Readium should fail to
        // open it, and the importer should not leave the copied file behind.
        let bogusSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-book-\(UUID().uuidString).epub")
        try "this is not an epub".write(to: bogusSourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bogusSourceURL) }

        await #expect(throws: Error.self) {
            _ = try await importer.importBook(from: bogusSourceURL, into: context)
        }

        let booksDirectory = try storage.booksDirectoryURL()
        let leftoverFiles = try FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)
        #expect(leftoverFiles.isEmpty, "expected the failed import's copied file to be cleaned up, found: \(leftoverFiles)")
        #expect(try context.fetch(FetchDescriptor<Book>()).isEmpty)
    }

    // MARK: - BookFileStorage in isolation

    @Test func bookFileStorageImportWriteAndDeleteRoundTrip() throws {
        let (storage, cleanup) = try Self.makeTempStorage()
        defer { cleanup() }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString).epub")
        try "fake epub bytes".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let id = UUID()
        let relativePath = try storage.importBookFile(from: sourceURL, id: id, fileExtension: "epub")
        #expect(relativePath == "\(id.uuidString).epub")

        let destinationURL = try storage.absoluteURL(forRelativePath: relativePath)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        let coverPath = try storage.writeCoverImage(Data("fake jpeg".utf8), id: id)
        #expect(coverPath == "\(id.uuidString)-cover.jpg")

        storage.deleteFile(atRelativePath: relativePath)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }
}
