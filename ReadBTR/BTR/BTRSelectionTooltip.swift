import SwiftUI

/// The shared long-press/selection tooltip (design-roadmap.md §6.6.1):
/// RSVP presents it directly over the current word; Guided Reading
/// presents the *same* component anchored to a native text selection's
/// frame (suppressing the native OS menu to do so). Normal mode is the one
/// activation site that deliberately does *not* use this — it appends a
/// single custom action to the native selection menu instead, per the
/// design doc's own wording.
///
/// `showsSaveQuote` swaps the leading action from Define to Save Quote —
/// Guided Reading's rule for a selection spanning more than one word
/// (§6.6.1); RSVP never sets it, since a single centered word is always
/// exactly one word.
struct BTRSelectionTooltip: View {
    var showsSaveQuote: Bool = false
    var showsViewSurrounding: Bool = true
    let onDefine: () -> Void
    var onViewSurrounding: (() -> Void)?
    var onSaveQuote: (() -> Void)?
    /// `nil` hides the BTR action — the reader's AI settings don't allow
    /// the BTR menu for this book.
    var onBTR: (() -> Void)?

    var body: some View {
        HStack(spacing: 20) {
            if showsSaveQuote, let onSaveQuote {
                action(systemImage: "quote.opening", label: "Save Quote", identifier: "save-quote", action: onSaveQuote)
            } else {
                action(systemImage: "character.book.closed", label: "Define", identifier: "define", action: onDefine)
            }
            if showsViewSurrounding, let onViewSurrounding {
                action(
                    systemImage: "text.book.closed", label: "View Surrounding", identifier: "view-surrounding",
                    action: onViewSurrounding)
            }
            if let onBTR {
                action(systemImage: "sparkles", label: "BTR", identifier: "btr", action: onBTR)
            }
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
