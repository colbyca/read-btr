import Foundation

/// The abstract, extensible key for every AI-powered feature in the app.
/// Adding a new AI feature anywhere means adding one case here — the config
/// page and the per-book override system both iterate `allCases` rather
/// than hardcoding a UI row per feature (design-roadmap.md §2.5).
enum AIFeatureKey: String, Codable, CaseIterable {
    case chapterSummary
    case entityExtraction
    case comprehensionCheck
    case questionAnswering

    var displayName: String {
        switch self {
        case .chapterSummary: "Chapter Summaries"
        case .entityExtraction: "Character & Location Lookup"
        case .comprehensionCheck: "Comprehension Checks"
        case .questionAnswering: "Ask About the Book"
        }
    }
}

/// One flag's state. Used both as `AppSettings.aiFeatureFlags` (one entry
/// per `AIFeatureKey`, global defaults) and sparsely inside
/// `BookSettingsOverride.aiFeatureFlagOverrides` (only explicitly-overridden
/// keys present; missing keys inherit the global flag).
struct AIFeatureFlag: Codable, Equatable {
    var key: AIFeatureKey
    var isEnabled: Bool
}

extension [AIFeatureFlag] {
    /// One disabled flag per `AIFeatureKey` — the safe, opt-in-by-default
    /// starting point for `AppSettings.aiFeatureFlags`.
    static var allDisabledByDefault: [AIFeatureFlag] {
        AIFeatureKey.allCases.map { AIFeatureFlag(key: $0, isEnabled: false) }
    }
}
