import SwiftUI

/// "Prompt them with the three options... should be an array of options" —
/// iterates `ReadingModeRegistry.all` rather than hardcoding a button per
/// mode (design-roadmap.md §3, §6.1).
struct ReadingModePickerSheet: View {
    let book: Book
    let onSelect: (ReadingModeID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ReadingModeRegistry.all) { descriptor in
                Button {
                    onSelect(descriptor.id)
                } label: {
                    Label(descriptor.displayName, systemImage: descriptor.systemImageName)
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
