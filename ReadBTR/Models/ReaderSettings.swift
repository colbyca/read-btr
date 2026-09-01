import Foundation

/// RSVP mode's tunables (design-roadmap.md §2.5, dev.md §2.1).
struct RSVPSettings: Codable, Equatable {
    var wordsPerMinute: Int
    var smartTimingEnabled: Bool
    var skipIncrementSmall: Int
    var skipIncrementMedium: Int
    var skipIncrementLarge: Int

    static let `default` = RSVPSettings(
        wordsPerMinute: 300,
        smartTimingEnabled: true,
        skipIncrementSmall: 5,
        skipIncrementMedium: 15,
        skipIncrementLarge: 30
    )
}

/// Guided Reading mode's tunables. Pacing is expressed in the same unit as
/// RSVP (`wordsPerMinute`) rather than a separate "lines per minute" concept
/// — one mental model for speed across both timed modes (design-roadmap.md §10).
/// Highlight granularity is a fixed on-screen *line* now (dev.md §4.3 —
/// real line-rect geometry, computed live off the rendered DOM — not a
/// user-configurable sentence/phrase choice), so there's no granularity
/// field to set here anymore.
struct GuidedReadingSettings: Codable, Equatable {
    var wordsPerMinute: Int

    static let `default` = GuidedReadingSettings(
        wordsPerMinute: 250
    )
}

enum NormalModeLayout: String, Codable {
    case scrolling
    case paginated
}

struct NormalModeSettings: Codable, Equatable {
    var layout: NormalModeLayout

    static let `default` = NormalModeSettings(layout: .paginated)
}

/// Bundles every reading mode's settings into one category-level unit.
/// `BookSettingsOverride.readerSettings` overrides this whole struct at
/// once, not field-by-field — see design-roadmap.md §2.5/§10 for why.
struct ReaderSettings: Codable, Equatable {
    var rsvp: RSVPSettings
    var guidedReading: GuidedReadingSettings
    var normalMode: NormalModeSettings

    static let `default` = ReaderSettings(
        rsvp: .default,
        guidedReading: .default,
        normalMode: .default
    )
}
