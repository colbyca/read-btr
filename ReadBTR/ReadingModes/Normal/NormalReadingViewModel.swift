import Foundation
import Observation
import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData

/// Drives the Normal reading screen (design-roadmap.md §6.5) — the
/// simplest of the three reading modes by design: it's just Readium's
/// stock `EPUBNavigatorViewController`, no custom rendering/highlighting
/// layer at all (dev.md §4.2). Unlike `GuidedReadingViewModel`, there's no
/// playback state, no line computation, and nothing to poll for readiness —
/// `loadState` reaches `.ready` synchronously once the publication opens
/// and the navigator constructs, since nothing here depends on the
/// navigator's view having already been laid out on screen.
@MainActor
@Observable
final class NormalReadingViewModel {
    enum LoadState: Equatable {
        case loading
        case failed(String)
        case ready
    }

    let book: Book

    private(set) var loadState: LoadState = .loading
    private(set) var navigatorHost: NormalReadingNavigatorController?
    private(set) var theme: ReaderTheme = .default
    private(set) var publication: Publication?

    var isShowingToolbar = false
    var isShowingChapterSelect = false
    var isShowingSettings = false

    /// The selection "BTR" was tapped for (design-roadmap.md §6.6.1) — set
    /// right before `isShowingBTRMenu` flips, so the `.fullScreenCover`'s
    /// content closure has something to anchor `BTRMenuView` to.
    private(set) var btrSelection: Selection?
    var isShowingBTRMenu = false

    private let modelContext: ModelContext
    private let fileStorage: BookFileStorage
    private let publicationLoader: PublicationLoader
    private var settings: NormalModeSettings = .default

    /// Overrides `NormalModeSettings.layout` regardless of the user's own
    /// Normal-mode preference — set by RSVP's "View Surrounding" (design-
    /// roadmap.md §6.6.1: "a modal presenting `NormalReadingView`... *in
    /// scrolling mode*") without touching the user's actual saved setting.
    /// `nil` (the default) means "use whatever the user has configured,"
    /// same as opening Normal reading mode normally.
    private let forcedLayout: NormalModeLayout?

    init(
        book: Book,
        modelContext: ModelContext,
        fileStorage: BookFileStorage = BookFileStorage(),
        publicationLoader: PublicationLoader = PublicationLoader(),
        forcedLayout: NormalModeLayout? = nil
    ) {
        self.book = book
        self.modelContext = modelContext
        self.fileStorage = fileStorage
        self.publicationLoader = publicationLoader
        self.forcedLayout = forcedLayout
    }

    func load() async {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).normalMode
        if let forcedLayout {
            settings.layout = forcedLayout
        }
        theme = book.effectiveTheme(appSettings)

        do {
            let fileURL = try fileStorage.absoluteURL(forRelativePath: book.relativeFilePath)
            let publication = try await publicationLoader.open(fileURL: fileURL)
            self.publication = publication

            let host = try NormalReadingNavigatorController(
                publication: publication,
                initialLocation: book.currentLocator,
                theme: theme,
                layout: settings.layout
            )
            wireNavigatorCallbacks(host)
            navigatorHost = host
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func wireNavigatorCallbacks(_ host: NormalReadingNavigatorController) {
        host.onLocationChange = { [weak self] locator in
            Task { @MainActor [weak self] in
                self?.persistPosition(from: locator)
                // Scrolling/turning a page while reading is the natural
                // "I'm reading again" signal, so it hides the toolbar the
                // same way resuming playback does in RSVP/Guided Reading —
                // there's no second "tap at top" to toggle it back off,
                // since once visible the toolbar itself physically covers
                // that same top zone (confirmed empirically: a tap there
                // lands on the navigation bar, not the page underneath).
                self?.isShowingToolbar = false
            }
        }
        host.onTopTap = { [weak self] in
            self?.isShowingToolbar = true
        }
        host.onBTRRequested = { [weak self] selection in
            self?.btrSelection = selection
            self?.isShowingBTRMenu = true
        }
    }

    /// Builds a fresh `BTRMenuViewModel` anchored at whatever selection
    /// "BTR" was last tapped for, or `nil` if there's nothing to anchor to
    /// (the menu item isn't reachable without a selection in practice, but
    /// this stays defensive rather than assuming that ordering).
    func makeBTRMenuViewModel() -> BTRMenuViewModel? {
        guard let publication, let locator = btrSelection?.locator else { return nil }
        let appSettings = AppSettingsStore.current(in: modelContext)
        let provider = AIProviderFactory.makeProvider(settings: appSettings, keyStore: AppSettings.keyStore)
        return BTRMenuViewModel(
            book: book, publication: publication, anchorLocator: locator, provider: provider,
            modelContext: modelContext)
    }

    /// Re-reads this book's *current* effective theme/settings and pushes
    /// them to the already-running navigator — called after the settings
    /// sheet is dismissed. `ConfigurationView` writes directly to the same
    /// `book`/`AppSettings` this view model already holds (same
    /// `modelContext`), but `theme`/`settings` here were only captured
    /// once, at `load()` time, so without this a change made mid-session
    /// silently wouldn't take effect until the mode was closed and
    /// reopened.
    func refreshSettings() {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).normalMode
        if let forcedLayout {
            settings.layout = forcedLayout
        }
        theme = book.effectiveTheme(appSettings)
        navigatorHost?.applyTheme(theme, layout: settings.layout)
    }

    /// Called by the chapter picker.
    func selectChapter(_ locator: Locator) async {
        guard let navigatorHost else { return }
        isShowingToolbar = false
        persistPosition(from: locator)
        _ = await navigatorHost.go(to: locator, animated: false)
    }

    private func persistPosition(from locator: Locator) {
        book.updatePosition(from: locator)
        try? modelContext.save()
    }
}
