import Foundation

/// Where imported book files actually live on disk, and the one place that
/// knows how to turn a `Book.relativeFilePath` into a real, readable URL.
///
/// Files live under `<Application Support>/Books/` — app-managed library
/// content, not something the user browses via the Files app, but still
/// included in the default iCloud device backup (design-roadmap.md §5.3).
struct BookFileStorage {
    enum StorageError: Error {
        case couldNotResolveApplicationSupportDirectory
    }

    private let fileManager: FileManager

    /// Overrides the resolved Application Support directory — production
    /// code always leaves this nil; tests pass a temp directory so runs
    /// don't touch or accumulate state in the real simulator/device storage.
    private let baseDirectoryOverride: URL?

    init(fileManager: FileManager = .default, baseDirectoryOverride: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectoryOverride
    }

    /// Never persist this URL itself — the app container's absolute path
    /// isn't stable across app updates, device restores, or reinstalls.
    /// Always resolve fresh and combine with a stored *relative* path
    /// (design-roadmap.md §5.3).
    func booksDirectoryURL() throws -> URL {
        let base: URL
        if let baseDirectoryOverride {
            base = baseDirectoryOverride
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StorageError.couldNotResolveApplicationSupportDirectory
            }
            base = appSupport
        }

        let booksDirectory = base.appendingPathComponent("Books", isDirectory: true)
        if !fileManager.fileExists(atPath: booksDirectory.path) {
            try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        }
        return booksDirectory
    }

    func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        try booksDirectoryURL().appendingPathComponent(relativePath)
    }

    /// Copies `sourceURL`'s contents into the Books directory as
    /// `<id>.<fileExtension>`, returning the path to store on
    /// `Book.relativeFilePath` — relative to the Books directory, never
    /// absolute. A generated UUID filename, not the original, so two books
    /// with the same source filename never collide.
    func importBookFile(from sourceURL: URL, id: UUID, fileExtension: String) throws -> String {
        let relativePath = "\(id.uuidString).\(fileExtension)"
        let destinationURL = try booksDirectoryURL().appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return relativePath
    }

    /// Writes JPEG cover data alongside the book file, sharing its `id` so
    /// the two files are trivially associated without any string surgery on
    /// the book's own relative path.
    func writeCoverImage(_ data: Data, id: UUID) throws -> String {
        let relativePath = "\(id.uuidString)-cover.jpg"
        let destinationURL = try booksDirectoryURL().appendingPathComponent(relativePath)
        try data.write(to: destinationURL, options: .atomic)
        return relativePath
    }

    func deleteFile(atRelativePath relativePath: String) {
        guard let url = try? absoluteURL(forRelativePath: relativePath) else { return }
        try? fileManager.removeItem(at: url)
    }
}
