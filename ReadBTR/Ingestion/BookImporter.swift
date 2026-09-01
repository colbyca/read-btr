import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import UIKit

enum BookImportError: LocalizedError {
    case couldNotDetermineStartingPosition

    var errorDescription: String? {
        switch self {
        case .couldNotDetermineStartingPosition:
            "This file doesn't look like a valid EPUB — ReadBTR couldn't find anything to read in it."
        }
    }
}

/// Turns a picked file URL into a persisted `Book` (design-roadmap.md §5).
///
/// Deliberately doesn't know about `.fileImporter` or security-scoped
/// resources — that's a SwiftUI/Home-page concern (§6.1). This assumes
/// `sourceURL` is already readable (the caller has already bracketed
/// `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()`
/// if needed) and handles the rest: copy into the sandbox, parse, extract
/// metadata + cover, build the initial position, persist.
struct BookImporter {
    private let fileStorage: BookFileStorage
    private let publicationLoader: PublicationLoader

    init(
        fileStorage: BookFileStorage = BookFileStorage(),
        publicationLoader: PublicationLoader = PublicationLoader()
    ) {
        self.fileStorage = fileStorage
        self.publicationLoader = publicationLoader
    }

    @MainActor
    func importBook(from sourceURL: URL, into context: ModelContext) async throws -> Book {
        let id = UUID()

        // Copy into our own sandbox first — a stable, app-owned file before
        // doing anything else. Readium needs a location it can keep reading
        // from long after the picker's security-scoped access window closes.
        let relativeFilePath = try fileStorage.importBookFile(
            from: sourceURL,
            id: id,
            fileExtension: "epub"
        )

        do {
            let bookFileURL = try fileStorage.absoluteURL(forRelativePath: relativeFilePath)
            let publication = try await publicationLoader.open(fileURL: bookFileURL)

            guard
                let firstLink = publication.readingOrder.first,
                let initialLocator = await publication.locate(firstLink)
            else {
                throw BookImportError.couldNotDetermineStartingPosition
            }

            let book = Book(
                id: id,
                title: publication.metadata.title ?? sourceURL.deletingPathExtension().lastPathComponent,
                author: publication.metadata.authors.first?.name,
                relativeFilePath: relativeFilePath,
                relativeCoverImagePath: await extractCover(from: publication, id: id),
                position: BookPosition(
                    locatorJSON: try initialLocator.jsonString(),
                    resourceHref: initialLocator.href.string,
                    updatedAt: .now
                )
            )
            context.insert(book)
            return book
        } catch {
            // Don't leave an orphaned, unreferenced file behind if anything
            // downstream failed.
            fileStorage.deleteFile(atRelativePath: relativeFilePath)
            throw error
        }
    }

    /// Cover extraction failure is never fatal to import — a book with no
    /// cover art is still a perfectly usable book, so this swallows errors
    /// and returns nil rather than throwing.
    private func extractCover(from publication: Publication, id: UUID) async -> String? {
        guard
            case let .success(image) = await publication.cover(),
            let image,
            let data = image.jpegData(compressionQuality: 0.85)
        else {
            return nil
        }
        return try? fileStorage.writeCoverImage(data, id: id)
    }
}
