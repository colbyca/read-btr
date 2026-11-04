import Foundation

/// The abstract, extensible key for every AI-powered feature in the app.
/// Adding a new AI feature anywhere means adding one case here — the config
/// page and the per-book override system both iterate `allCases` rather
/// than hardcoding a UI row per feature (design-roadmap.md §2.5).
enum AIFeatureKey: String, Codable, CaseIterable {
    /// The BTR chat: ask anything about the book, spoiler-free
    /// (design-roadmap.md §6.6).
    case btrChat

    var displayName: String {
        switch self {
        case .btrChat: "BTR Chat"
        }
    }

    /// Raw values written by older builds, before the BTR menu became the
    /// BTR chat. Saved settings may still contain them, so decoding has to
    /// keep accepting them rather than failing the whole settings record.
    /// The old menu options all fold into the chat; comprehension checks
    /// were removed outright, so a saved flag for them carries no meaning.
    enum LegacyRawValue: String {
        case chapterSummary, entityExtraction, questionAnswering
        case comprehensionCheck

        var replacement: AIFeatureKey { .btrChat }
        /// Whether the saved on/off value still means something for the
        /// replacement key.
        var carriesOverEnabledState: Bool { self != .comprehensionCheck }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let key = AIFeatureKey(rawValue: raw) {
            self = key
        } else if let legacy = LegacyRawValue(rawValue: raw) {
            self = legacy.replacement
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown AI feature key \(raw)"))
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

    /// True when this flag was decoded from a key that no longer exists
    /// (comprehension checks). Never encoded: `normalized` drops these.
    private(set) var isRetired = false

    private enum CodingKeys: String, CodingKey {
        case key, isEnabled
    }

    init(key: AIFeatureKey, isEnabled: Bool) {
        self.key = key
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .key)
        let decodedEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        if let key = AIFeatureKey(rawValue: raw) {
            self.key = key
            isEnabled = decodedEnabled
        } else if let legacy = AIFeatureKey.LegacyRawValue(rawValue: raw) {
            key = legacy.replacement
            isEnabled = legacy.carriesOverEnabledState && decodedEnabled
            isRetired = !legacy.carriesOverEnabledState
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: container, debugDescription: "Unknown AI feature key \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    static func == (lhs: AIFeatureFlag, rhs: AIFeatureFlag) -> Bool {
        lhs.key == rhs.key && lhs.isEnabled == rhs.isEnabled && lhs.isRetired == rhs.isRetired
    }
}

extension [AIFeatureFlag] {
    /// One disabled flag per `AIFeatureKey` — the safe, opt-in-by-default
    /// starting point for `AppSettings.aiFeatureFlags`.
    static var allDisabledByDefault: [AIFeatureFlag] {
        AIFeatureKey.allCases.map { AIFeatureFlag(key: $0, isEnabled: false) }
    }

    /// At most one flag per key, with retired legacy flags dropped. Older
    /// builds had several menu features that now all map to the BTR chat,
    /// so a decoded array can hold duplicates: the chat counts as on if any
    /// of the old features was on.
    var normalized: [AIFeatureFlag] {
        var result: [AIFeatureFlag] = []
        for flag in self where !flag.isRetired {
            if let index = result.firstIndex(where: { $0.key == flag.key }) {
                result[index].isEnabled = result[index].isEnabled || flag.isEnabled
            } else {
                result.append(AIFeatureFlag(key: flag.key, isEnabled: flag.isEnabled))
            }
        }
        return result
    }

    /// The effective state for `key`, tolerant of un-normalized arrays.
    func flag(for key: AIFeatureKey) -> AIFeatureFlag? {
        normalized.first { $0.key == key }
    }
}
