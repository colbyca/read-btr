import SwiftData
import SwiftUI

/// Name a new collection and pick its first books, in reading order.
struct NewCollectionSheet: View {
    /// Books to start with — e.g. the book whose "Add to Collection ▸ New
    /// Collection…" menu opened this.
    var initialBooks: [Book] = []
    var onCreated: (BookCollection) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var library: [Book]

    @State private var name = ""
    @State private var books: [Book] = []
    @State private var isPickingBooks = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Collection name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("new-collection-name")
                } footer: {
                    Text("For example, a series. You can add, remove and reorder books at any time.")
                }

                Section {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 20)
                            Text(book.title)
                                .lineLimit(2)
                        }
                    }
                    .onMove { books.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { books.remove(atOffsets: $0) }

                    if books.count < library.count {
                        Button("Add Books from Library", systemImage: "plus") {
                            isPickingBooks = true
                        }
                        .accessibilityIdentifier("new-collection-add-books")
                    }
                } header: {
                    Text("Books, in reading order")
                } footer: {
                    Text(
                        "The BTR chat treats earlier books as already read and never looks at later ones, so keep "
                            + "this in reading order to avoid spoilers. Drag to reorder.")
                }
            }
            .environment(\.editMode, .constant(books.count > 1 ? .active : .inactive))
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("new-collection-create")
                }
            }
            .sheet(isPresented: $isPickingBooks) {
                BookPickerSheet(
                    title: "Add Books", confirmLabel: "Add", excluding: Set(books.map(\.id))
                ) { picked in
                    books += picked
                }
            }
            .onAppear {
                if books.isEmpty { books = initialBooks }
                isNameFocused = true
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let collection = BookCollection(name: trimmedName)
        modelContext.insert(collection)
        for book in books {
            collection.append(book, in: modelContext)
        }
        try? modelContext.save()
        onCreated(collection)
        dismiss()
    }
}
