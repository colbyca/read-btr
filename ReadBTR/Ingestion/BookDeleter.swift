import Foundation
import SwiftData

/// Removes a book from the library: its SwiftData record (which cascades to
/// its chapter summaries, entity profiles, and saved quotes, per `Book`'s
/// relationship delete rules) plus the EPUB and cover files it owns under
/// `<Application Support>/Books/`. The mirror image of `BookImporter`.
struct BookDeleter {
    private let fileStorage: BookFileStorage

    init(fileStorage: BookFileStorage = BookFileStorage()) {
        self.fileStorage = fileStorage
    }

    /// The model is deleted and saved first, then the files. If the save
    /// fails nothing on disk is touched, so the library never ends up with
    /// a record pointing at a missing file.
    @MainActor
    func delete(_ book: Book, from context: ModelContext) throws {
        let relativePaths = [book.relativeFilePath] + [book.relativeCoverImagePath].compactMap { $0 }
        context.delete(book)
        try context.save()
        for path in relativePaths {
            fileStorage.deleteFile(atRelativePath: path)
        }
    }
}
