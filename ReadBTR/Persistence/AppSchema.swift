import SwiftData

/// Every SwiftData model the app stores — one list shared by the app's
/// container, SwiftUI previews and the tests, so a new model can't be
/// registered in one place and forgotten in another.
///
/// Older builds also stored `ChapterSummary`, `EntityProfile` (the BTR
/// menu's caches) and `ComprehensionCheck`. Dropping a model is a
/// lightweight migration SwiftData performs on its own: those tables are
/// simply removed the first time this schema opens an older store.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Book.self,
        AppSettings.self,
        SavedQuote.self,
        BookCollection.self,
        CollectionEntry.self,
    ]
}
