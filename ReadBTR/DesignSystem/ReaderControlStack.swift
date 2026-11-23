import SwiftUI

/// The chapter-select button with the settings button below it, floating
/// just under the top-trailing corner of the navigation bar. It lives
/// outside the toolbar because a bar can't fit two full-size buttons stacked
/// vertically, and leaving the trailing slot empty keeps the chapter header
/// centered.
private struct ReaderControlStack: ViewModifier {
    let isVisible: Bool
    let identifierPrefix: String
    let onChapterSelect: () -> Void
    let onSettings: () -> Void

    func body(content: Content) -> some View {
        ZStack(alignment: .topTrailing) {
            content
            if isVisible {
                VStack(spacing: 0) {
                    button(systemImage: "list.bullet", label: "Chapters", suffix: "chapter-select", action: onChapterSelect)
                    button(systemImage: "gearshape", label: "Settings", suffix: "settings", action: onSettings)
                }
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .animation(.default, value: isVisible)
    }

    private func button(
        systemImage: String,
        label: String,
        suffix: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifierPrefix)-\(suffix)")
    }
}

extension View {
    func readerControlStack(
        isVisible: Bool,
        identifierPrefix: String,
        onChapterSelect: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) -> some View {
        modifier(ReaderControlStack(
            isVisible: isVisible,
            identifierPrefix: identifierPrefix,
            onChapterSelect: onChapterSelect,
            onSettings: onSettings
        ))
    }
}
