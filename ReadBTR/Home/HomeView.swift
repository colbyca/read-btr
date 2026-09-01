import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The library screen — a 3-wide grid of books with a pinned "add" tile,
/// search, and a settings entry point (design-roadmap.md §6.1).
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]

    @State private var searchText = ""
    @State private var isShowingFileImporter = false
    @State private var isShowingSettings = false
    @State private var isShowingImportError = false
    @State private var importErrorMessage = ""
    @State private var bookPendingModeSelection: Book?
    @State private var activeReadingSession: ReadingSession?

    #if DEBUG
        @State private var isShowingNavigatorSpike = false
    #endif

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    /// Simple in-memory filter — library sizes are personal-scale, no need
    /// for a SwiftData `#Predicate`-backed search index (design-roadmap.md §6.1).
    /// Sorted most-recently-opened first, falling back to most-recently-added
    /// for books that have never been opened.
    private var filteredBooks: [Book] {
        let sorted = books.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    AddBookTile { isShowingFileImporter = true }

                    ForEach(filteredBooks) { book in
                        Button {
                            bookPendingModeSelection = book
                        } label: {
                            BookCoverView(book: book)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("book-\(book.id)")
                    }
                }
                .padding()
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search your books")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("home-settings")
                }
                #if DEBUG
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Seed alice.epub") {
                                Task { await seedFixtureBook() }
                            }
                            Button("Reset Library", role: .destructive) {
                                DevSeeder.resetLibrary(context: modelContext)
                            }
                            Button("Readium Navigator Spike") { isShowingNavigatorSpike = true }
                        } label: {
                            Image(systemName: "ladybug")
                        }
                        .accessibilityIdentifier("dev-menu")
                    }
                #endif
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.epub],
                onCompletion: handleFileImport
            )
            .sheet(isPresented: $isShowingSettings) {
                ConfigurationView()
            }
            .sheet(item: $bookPendingModeSelection) { book in
                ReadingModePickerSheet(book: book) { mode in
                    bookPendingModeSelection = nil
                    activeReadingSession = ReadingSession(book: book, mode: mode)
                }
            }
            .fullScreenCover(item: $activeReadingSession) { session in
                ReadingModeRegistry.makeView(for: session.mode, book: session.book)
            }
            #if DEBUG
                .fullScreenCover(isPresented: $isShowingNavigatorSpike) {
                    ReadiumNavigatorSpikeScreen()
                }
            #endif
            .alert("Couldn't Add Book", isPresented: $isShowingImportError) {
                Button("OK") {}
            } message: {
                Text(importErrorMessage)
            }
            #if DEBUG
                .task {
                    await DevSeeder.seedIfLibraryEmpty(context: modelContext)
                }
            #endif
        }
    }

    #if DEBUG
        private func seedFixtureBook() async {
            do {
                try await DevSeeder.seedAliceInWonderland(into: modelContext)
            } catch {
                presentImportError(error.localizedDescription)
            }
        }
    #endif

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { await importBook(from: url) }
        case .failure(let error):
            presentImportError(error.localizedDescription)
        }
    }

    private func importBook(from url: URL) async {
        // `.fileImporter` hands back a security-scoped URL — access must be
        // explicitly bracketed before `BookImporter` (which assumes an
        // already-readable URL) can read it (design-roadmap.md §5.2).
        guard url.startAccessingSecurityScopedResource() else {
            presentImportError("Couldn't access the selected file.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            _ = try await BookImporter().importBook(from: url, into: modelContext)
        } catch {
            presentImportError(error.localizedDescription)
        }
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        isShowingImportError = true
    }
}

private struct ReadingSession: Identifiable {
    let book: Book
    let mode: ReadingModeID
    var id: String { "\(book.id)-\(mode.rawValue)" }
}
