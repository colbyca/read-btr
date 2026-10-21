import SwiftUI

/// A brief "Quote saved" capsule at the bottom of a reading screen, shown
/// each time `trigger` changes to a new non-nil value.
private struct QuoteSavedToastModifier: ViewModifier {
    let trigger: UUID?

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isVisible {
                    Label("Quote saved", systemImage: "quote.opening")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4)
                        .padding(.bottom, 48)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("quote-saved-toast")
                }
            }
            .animation(.default, value: isVisible)
            .task(id: trigger) {
                guard trigger != nil else { return }
                isVisible = true
                do {
                    try await Task.sleep(for: .seconds(1.5))
                } catch {
                    return
                }
                isVisible = false
            }
    }
}

extension View {
    func quoteSavedToast(trigger: UUID?) -> some View {
        modifier(QuoteSavedToastModifier(trigger: trigger))
    }
}
