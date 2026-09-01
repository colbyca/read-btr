import Foundation
@preconcurrency import ReadiumShared
import SwiftData

enum BookFormat: String, Codable {
    case epub
}

/// The aggregate root — deliberately thin on its own fields, heavy on
/// composition. The "conglomerate source of truth" the product spec asks
/// for, assembled from the pieces in this folder rather than a model that
/// redefines them inline (design-roadmap.md §2.2).
@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var format: BookFormat

    /// Relative to `<Application Support>/Books/` — never store an absolute
    /// path here. The app container's absolute path is not stable across
    /// app updates, device restores, or reinstalls (design-roadmap.md §5.3).
    var relativeFilePath: String
    var relativeCoverImagePath: String?

    var addedAt: Date
    var lastOpenedAt: Date?

    /// Canonical current reading position, shared across all three reading
    /// modes (design-roadmap.md §2.3, §4).
    var position: BookPosition

    /// Called out explicitly by the product spec as living directly on
    /// Book, separate from `settingsOverride`. When set, the reader UI uses
    /// this instead of `AppSettings.defaultTheme`.
    var themeOverride: ReaderTheme?

    /// Everything else overridable per-book: reading-mode settings and AI
    /// feature flags (design-roadmap.md §2.5).
    var settingsOverride: BookSettingsOverride?

    @Relationship(deleteRule: .cascade, inverse: \ChapterSummary.book)
    var chapterSummaries: [ChapterSummary] = []

    @Relationship(deleteRule: .cascade, inverse: \EntityProfile.book)
    var entityProfiles: [EntityProfile] = []

    @Relationship(deleteRule: .cascade, inverse: \SavedQuote.book)
    var savedQuotes: [SavedQuote] = []

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        format: BookFormat = .epub,
        relativeFilePath: String,
        relativeCoverImagePath: String? = nil,
        addedAt: Date = .now,
        lastOpenedAt: Date? = nil,
        position: BookPosition,
        themeOverride: ReaderTheme? = nil,
        settingsOverride: BookSettingsOverride? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.relativeFilePath = relativeFilePath
        self.relativeCoverImagePath = relativeCoverImagePath
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.position = position
        self.themeOverride = themeOverride
        self.settingsOverride = settingsOverride
    }
}

extension Book: Identifiable {}

// MARK: - Effective settings resolution (design-roadmap.md §2.5)

extension Book {
    func effectiveReaderSettings(_ global: AppSettings) -> ReaderSettings {
        settingsOverride?.readerSettings ?? global.defaultReaderSettings
    }

    func effectiveTheme(_ global: AppSettings) -> ReaderTheme {
        themeOverride ?? global.defaultTheme
    }

    func isAIFeatureEnabled(_ key: AIFeatureKey, _ global: AppSettings) -> Bool {
        guard global.aiProviderIsUsable, global.aiFeaturesMasterToggle else { return false }
        if let override = settingsOverride?.aiFeatureFlagOverrides.first(where: { $0.key == key }) {
            return override.isEnabled
        }
        return global.aiFeatureFlag(for: key)?.isEnabled ?? false
    }
}

// MARK: - Position (design-roadmap.md §4.5)
//
// Every reading-mode view's job on appear is: read `currentLocator` (or, for
// RSVP, `currentRSVPIndex`), nothing else — the mode itself never has to
// know how the user got there.

extension Book {
    /// Normal/Guided Reading call this from `NavigatorDelegate.locationDidChange`.
    /// RSVP calls it with the current word's own locator whenever its index
    /// changes — that direction is exact, no approximation needed
    /// (design-roadmap.md §4.4).
    func updatePosition(from locator: Locator) {
        guard let locatorJSON = try? locator.jsonString() else { return }
        position = BookPosition(
            locatorJSON: locatorJSON,
            resourceHref: locator.href.string,
            updatedAt: .now
        )
    }

    /// What Normal/Guided Reading consume directly.
    var currentLocator: Locator? {
        try? Locator(jsonString: position.locatorJSON)
    }

    /// What RSVP consumes — resolves the current locator against a word
    /// stream for its resource, building/reusing one via `cache`
    /// (design-roadmap.md §4.5). `cache` is owned by the caller (the RSVP
    /// session), so its lifetime — and eviction — is just "however long that
    /// session lasts."
    @MainActor
    func currentRSVPIndex(publication: Publication, cache: WordStreamCache) async -> (stream: WordStream, index: Int)? {
        guard let locator = currentLocator else { return nil }
        guard let stream = await cache.stream(for: locator.href.string, in: publication) else { return nil }

        guard !stream.words.isEmpty else {
            // The resource at the saved position has no extractable text
            // (e.g. a cover-image wrapper page) — skip forward to the next
            // resource that actually has words rather than resolving to an
            // unusable empty stream.
            guard let nonEmpty = await cache.firstNonEmptyStream(from: stream.resourceHref, in: publication) else {
                return nil
            }
            return (nonEmpty, 0)
        }

        let index = RSVPPositionResolver.wordIndex(for: locator, in: stream)
        return (stream, index)
    }
}
