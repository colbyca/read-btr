import SwiftUI

/// The pinned first cell in the library grid — sized to match
/// `BookCoverView` so it sits naturally in the same grid, always first
/// (design-roadmap.md §6.1).
struct AddBookTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                Text("Add Book")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(2 / 3, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            )
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Book")
    }
}
