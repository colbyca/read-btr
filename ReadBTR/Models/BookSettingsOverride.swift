import Foundation

/// Everything overridable per-book *other than* the theme (which lives
/// directly on `Book`, per the product spec) — reading-mode settings and AI
/// feature flags. Embedded on `Book` as a `Codable` value, not a SwiftData
/// relationship, since it's inherently 1:1 with its owner and never queried
/// independently (design-roadmap.md §2.1, §2.5).
struct BookSettingsOverride: Codable, Equatable {
    /// nil = inherit `AppSettings.defaultReaderSettings` entirely. Set as a
    /// whole clone of the current effective settings the first time the user
    /// edits any per-book reading setting — category-level override, not
    /// field-level (design-roadmap.md §10).
    var readerSettings: ReaderSettings?

    /// Sparse: only entries the user has explicitly overridden for this
    /// book appear here. A missing key inherits the global flag.
    var aiFeatureFlagOverrides: [AIFeatureFlag] = []
}
