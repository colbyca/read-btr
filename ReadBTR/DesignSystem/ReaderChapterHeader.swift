import SwiftUI

/// The current chapter's title with a bar under it showing how far into
/// that chapter the reader is — shown in the center of every reading
/// mode's top toolbar while it's revealed.
struct ReaderChapterHeader: View {
    let title: String
    /// 0...1 through the current chapter.
    let progress: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("reader-chapter-title")
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .accessibilityIdentifier("reader-chapter-progress")
                .accessibilityLabel("Chapter progress")
                .accessibilityValue(Text("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent"))
        }
        // Takes whatever room the toolbar leaves between its leading and
        // trailing buttons, so full chapter titles fit where they can.
        .frame(minWidth: 180, maxWidth: .infinity)
    }
}
