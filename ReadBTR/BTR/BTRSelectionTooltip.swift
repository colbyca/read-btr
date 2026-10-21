import SwiftUI

/// The shared long-press/selection tooltip (design-roadmap.md §6.6.1):
/// RSVP presents it directly over the current word; Guided Reading
/// presents the *same* component anchored to a native text selection's
/// frame (suppressing the native OS menu to do so). Normal mode is the one
/// activation site that deliberately does *not* use this — it appends a
/// single custom action to the native selection menu instead, per the
/// design doc's own wording.
///
/// Which leading actions appear depends on the mode: Guided Reading shows
/// Define for a single word and Save Quote for a multi-word selection
/// (§6.6.1); RSVP shows both, since its Save Quote saves the sentence
/// around the current word. Save Quote appears whenever `onSaveQuote` is
/// set.
struct BTRSelectionTooltip: View {
    var showsDefine: Bool = true
    var showsViewSurrounding: Bool = true
    let onDefine: () -> Void
    var onViewSurrounding: (() -> Void)?
    var onSaveQuote: (() -> Void)?
    let onBTR: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            if showsDefine {
                action(systemImage: "character.book.closed", label: "Define", identifier: "define", action: onDefine)
            }
            if let onSaveQuote {
                action(systemImage: "quote.opening", label: "Save Quote", identifier: "save-quote", action: onSaveQuote)
            }
            if showsViewSurrounding, let onViewSurrounding {
                action(
                    systemImage: "text.book.closed", label: "View Surrounding", identifier: "view-surrounding",
                    action: onViewSurrounding)
            }
            action(systemImage: "sparkles", label: "BTR", identifier: "btr", action: onBTR)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
        .accessibilityIdentifier("btr-selection-tooltip")
    }

    private func action(
        systemImage: String, label: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(label)
                    .font(.caption2)
            }
        }
        .accessibilityIdentifier("btr-tooltip-\(identifier)")
    }
}
