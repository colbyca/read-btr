import Foundation

/// The canonical current reading position for a `Book`, shared across all
/// reading modes (design-roadmap.md §2.3, §4).
///
/// `locatorJSON` is a serialized Readium `Locator` — the format every
/// reading mode ultimately reads from or resolves to (design-roadmap.md §4).
struct BookPosition: Codable, Equatable {
    var locatorJSON: String
    var resourceHref: String
    var updatedAt: Date
}
