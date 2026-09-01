import Foundation

/// Which AI backend is selected. Adding a provider is one case here plus one
/// new `AIProvider` conformance (design-roadmap.md §2.7/§2.8, dev.md §3) —
/// nothing else in the app needs to change.
enum AIProviderKind: String, Codable, CaseIterable {
    case gemini

    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        }
    }
}
