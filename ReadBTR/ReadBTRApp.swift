import SwiftData
import SwiftUI

@main
struct ReadBTRApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Book.self,
            AppSettings.self,
            ChapterSummary.self,
            EntityProfile.self,
            SavedQuote.self,
            ComprehensionCheck.self,
        ])
    }
}
