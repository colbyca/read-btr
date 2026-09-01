import SwiftUI

/// Shared layout for the three not-yet-built reading modes, so
/// RSVPView/GuidedReadingView/NormalReadingView stay separate, real types
/// (each will be replaced independently as its own module lands) without
/// tripling this boilerplate in the meantime.
struct ReadingModePlaceholderView: View {
    let book: Book
    let modeName: String
    let systemImageName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: systemImageName)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(book.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("\(modeName) — coming soon")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
