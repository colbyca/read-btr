import SwiftUI

struct ContentView: View {
    var body: some View {
        HomeView()
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [Book.self, AppSettings.self, ChapterSummary.self, EntityProfile.self, SavedQuote.self, ComprehensionCheck.self],
            inMemory: true
        )
}
