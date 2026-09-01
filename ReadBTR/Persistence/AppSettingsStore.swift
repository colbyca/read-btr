import Foundation
import SwiftData

/// SwiftData has no native singleton concept. Exactly one `AppSettings` row
/// should exist; every screen reads/writes through this helper rather than
/// querying `AppSettings` directly (design-roadmap.md §2.6).
enum AppSettingsStore {
    @MainActor
    static func current(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }

        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}
