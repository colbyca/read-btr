import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One collection: its books in reading order, with everything needed to
/// manage it — add books from the library or import new ones, drag to
/// reorder, swipe to remove, rename, delete (design-roadmap.md §6.1.1).
/// Tapping a book opens it, the same as from the library grid.
struct CollectionDetailView: View {
    @Bindable var collection: BookCollection
    let onOpenBook: (Book) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var isPickingBooks = false
    @State private var isImporting = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(Array(collection.orderedBooks.enumerated()), id: \.element.id) { index, book in
                    Button {
                        onOpenBook(book)
                    } label: {
                        CollectionBookRow(book: book, number: index + 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("collection-book-\(index)")
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            remove(book)
                        }
                    }
                }
                .onMove { source, destination in
                    collection.move(fromOffsets: source, toOffset: destination)
                    save()
                }
                .onDelete { offsets in
                    let books = collection.orderedBooks
                    for offset in offsets { remove(books[offset]) }
                }

                Menu {
                    addBooksMenu
                } label: {
                    Label("Add Books", systemImage: "plus")
                }
                .accessibilityIdentifier("collection-add-books")
            } footer: {
                Text(footer)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(collection.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if collection.orderedBooks.count > 1 {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .accessibilityIdentifier("collection-reorder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        renameText = collection.name
                        isRenaming = true
                    }
                    Button("Delete Collection", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .accessibilityIdentifier("collection-delete")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("collection-more")
            }
        }
        .sheet(isPresented: $isPickingBooks) {
            BookPickerSheet(
                title: "Add to \(collection.name)", confirmLabel: "Add",
                excluding: Set(collection.orderedBooks.map(\.id))
            ) { books in
                for book in books { collection.append(book, in: modelContext) }
                save()
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.epub]) { result in
            switch result {
            case .success(let url): Task { await importBook(from: url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Rename Collection", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    collection.name = name
                    save()
                }
            }
        }
        .confirmationDialog(
            "Delete “\(collection.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                // Leave the screen first, so nothing renders the collection
                // after it's gone.
                let collection = collection
                let context = modelContext
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    context.delete(collection)
                    try? context.save()
                }
            }
            .accessibilityIdentifier("confirm-delete-collection")
        } message: {
            Text("The books stay in your library.")
        }
        .alert(
            "Couldn't Add Book",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var addBooksMenu: some View {
        Button("From Library", systemImage: "books.vertical") { isPickingBooks = true }
            .accessibilityIdentifier("collection-add-from-library")
        Button("Import EPUB", systemImage: "doc.badge.plus") { isImporting = true }
            .accessibilityIdentifier("collection-import")
    }

    private var footer: String {
        if collection.orderedBooks.isEmpty {
            return "Add books in the order they're meant to be read."
        }
        return "Keep books in reading order: when you ask the BTR chat about a book, it can use the books "
            + "before it here, but never the ones after it, so nothing gets spoiled."
    }

    private func remove(_ book: Book) {
        collection.remove(book, in: modelContext)
        save()
    }

    private func save() {
        try? modelContext.save()
    }

    private func importBook(from url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let book = try await BookImporter().importBook(from: url, into: modelContext)
            collection.append(book, in: modelContext)
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CollectionBookRow: View {
    let book: Book
    let number: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22)
            BookCoverView(book: book)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
