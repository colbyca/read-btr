import SwiftUI

/// The list of reading modes is data, not a hardcoded set of screens — Home
/// iterates `ReadingModeRegistry.all`, not three separate buttons. Adding a
/// fourth mode means adding one case here, one descriptor below, and one
/// branch in `makeView` — nowhere else (design-roadmap.md §3).
enum ReadingModeID: String, Codable, CaseIterable, Identifiable {
    case rsvp
    case guidedReading
    case normal

    var id: String { rawValue }
}

struct ReadingModeDescriptor: Identifiable {
    let id: ReadingModeID
    let displayName: String
    let systemImageName: String
}

enum ReadingModeRegistry {
    static let all: [ReadingModeDescriptor] = [
        ReadingModeDescriptor(id: .rsvp, displayName: "RSVP", systemImageName: "text.word.spacing"),
        ReadingModeDescriptor(
            id: .guidedReading,
            displayName: "Guided Reading",
            systemImageName: "text.line.first.and.arrowtriangle.forward"
        ),
        ReadingModeDescriptor(id: .normal, displayName: "Normal", systemImageName: "book"),
    ]

    @MainActor
    @ViewBuilder
    static func makeView(for id: ReadingModeID, book: Book) -> some View {
        switch id {
        case .rsvp: RSVPView(book: book)
        case .guidedReading: GuidedReadingView(book: book)
        case .normal: NormalReadingView(book: book)
        }
    }
}
