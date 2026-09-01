import SwiftUI

/// One selectable character/location chip in the BTR options panel
/// (design-roadmap.md §6.6.3 step 1). Plain `Capsule` button — the first
/// real chip component in the app, kept local to `BTR/` rather than
/// `DesignSystem/` since nothing else needs a chip yet; promote it if a
/// second feature ever does.
struct BTREntityChip: View {
    let entity: ExtractedEntity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(entity.name, systemImage: symbolName)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("btr-entity-chip-\(entity.name)")
    }

    private var symbolName: String {
        switch entity.kind {
        case .character: "person.fill"
        case .location: "mappin.and.ellipse"
        }
    }
}
