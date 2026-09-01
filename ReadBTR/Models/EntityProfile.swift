import Foundation
import SwiftData

enum EntityKind: String, Codable {
    case character
    case location
}

/// An AI-generated character/location summary produced by the BTR menu's
/// entity-extraction pipeline (design-roadmap.md §2.10, §6.6.3).
///
/// Dedup rule: before firing the "gather context + summarize" request,
/// check `book.entityProfiles` for a `canonicalName` match. If found, show
/// it immediately — no new API call. Known MVP limitation: exact/normalized
/// string match only ("Alice" and "Alice Liddell" won't merge).
@Model
final class EntityProfile {
    var id: UUID

    /// Trimmed + lowercased — the dedup key.
    var canonicalName: String

    /// Original casing, for UI.
    var displayName: String

    var kind: EntityKind
    var summary: String
    var firstMentionLocatorJSON: String
    var generatedAt: Date
    var book: Book?

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: EntityKind,
        summary: String,
        firstMentionLocatorJSON: String,
        generatedAt: Date = .now,
        book: Book? = nil
    ) {
        self.id = id
        self.canonicalName = EntityProfile.canonicalize(displayName)
        self.displayName = displayName
        self.kind = kind
        self.summary = summary
        self.firstMentionLocatorJSON = firstMentionLocatorJSON
        self.generatedAt = generatedAt
        self.book = book
    }

    static func canonicalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
