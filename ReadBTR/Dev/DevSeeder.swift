#if DEBUG
import Foundation
import SwiftData

/// Dev-only convenience for standing up a library entry without going
/// through the file picker every time — lets manual testing of import and
/// the reading engine start from a real, already-imported book. Routes
/// through the real `BookImporter`/`PublicationLoader` pipeline against the
/// same `alice.epub` fixture already bundled for the Readium spikes
/// (dev.md §9), so it exercises the actual import code path rather than
/// hand-building a `Book`. Compiled out of Release builds entirely.
enum DevSeeder {
    enum SeedError: LocalizedError {
        case fixtureNotFound

        var errorDescription: String? {
            switch self {
            case .fixtureNotFound:
                "Couldn't find the bundled alice.epub fixture."
            }
        }
    }

    /// Imports the bundled fixture as a new `Book`. Call directly (e.g. from
    /// a debug menu) when you want another copy to test with; use
    /// `seedIfLibraryEmpty` for the "just give me something to read on
    /// launch" case.
    @MainActor
    @discardableResult
    static func seedAliceInWonderland(into context: ModelContext) async throws -> Book {
        guard let fixtureURL = Bundle.main.url(forResource: "alice", withExtension: "epub") else {
            throw SeedError.fixtureNotFound
        }
        let book = try await BookImporter().importBook(from: fixtureURL, into: context)
        try context.save()
        return book
    }

    /// Seeds only if the library is empty — safe to call unconditionally on
    /// every launch (e.g. from `HomeView`'s `.task`) without piling up
    /// duplicate copies across relaunches of a simulator that kept its data.
    @MainActor
    static func seedIfLibraryEmpty(context: ModelContext) async {
        let existing = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        guard existing.isEmpty else { return }
        try? await seedAliceInWonderland(into: context)
    }

    /// Wipes the library back to empty — the other half of a fast
    /// re-test loop (seed → exercise import/reading engine → reset →
    /// reseed) without deleting the app or resetting the simulator.
    @MainActor
    static func resetLibrary(context: ModelContext) {
        let fileStorage = BookFileStorage()
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books {
            fileStorage.deleteFile(atRelativePath: book.relativeFilePath)
            if let coverPath = book.relativeCoverImagePath {
                fileStorage.deleteFile(atRelativePath: coverPath)
            }
            context.delete(book)
        }
        try? context.save()
    }
}
#endif
