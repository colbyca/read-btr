import SwiftData
import SwiftUI

@main
struct ReadBTRApp: App {
    init() {
        #if DEBUG
            UITestHooks.installKeyStoreIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: AppSchema.models)
    }
}
