import Foundation
import Observation
@preconcurrency import ReadiumShared
import SwiftData

/// Drives the RSVP reading screen (design-roadmap.md §6.3): loads the
/// publication, resolves the book's current position into a word index
/// (§4.5), and owns playback/seeking from there. `@MainActor`, matching the
/// concurrency convention used by every other service in this codebase.
@MainActor
@Observable
final class RSVPViewModel {
    enum LoadState: Equatable {
        case loading
        case failed(String)
        case ready
    }

    let book: Book

    private(set) var loadState: LoadState = .loading
    private(set) var currentStream: WordStream?
    private(set) var currentIndex = 0
    private(set) var theme: ReaderTheme = .default
    private(set) var publication: Publication?

    var isPlaying = false
    var isShowingToolbar = false
    var isShowingChapterSelect = false
    var isShowingSettings = false

    /// BTR activation state (design-roadmap.md §6.6.1): long-pressing the
    /// current word shows the shared tooltip; its three actions each own
    /// their own presentation flag rather than one enum, since — unlike
    /// the reading-mode toolbar's mutually-exclusive sheets — nothing stops
    /// a future design from wanting more than one active at once, and it
    /// keeps each `.sheet`/`.fullScreenCover` binding trivial.
    var isShowingBTRTooltip = false
    var isShowingDictionary = false
    var isShowingSurroundingView = false
    var isShowingBTRMenu = false

    private let modelContext: ModelContext
    private let publicationLoader: PublicationLoader
    private let wordStreamCache = WordStreamCache()
    private var settings: RSVPSettings = .default
    private var playbackTask: Task<Void, Never>?

    /// Safety bound on how many adjacent resources `step(by:)` will cross
    /// in one call — protects against an unbounded loop if a book somehow
    /// had many consecutive empty resources back to back.
    private static let maxResourceCrossings = 25

    private let fileStorage: BookFileStorage

    init(
        book: Book,
        modelContext: ModelContext,
        fileStorage: BookFileStorage = BookFileStorage(),
        publicationLoader: PublicationLoader = PublicationLoader()
    ) {
        self.book = book
        self.modelContext = modelContext
        self.fileStorage = fileStorage
        self.publicationLoader = publicationLoader
    }

    var currentWord: String? {
        wordSegment(at: currentIndex)?.text
    }

    /// The current word's own locator — what BTR's "position the menu
    /// opened at" and "View Surrounding"'s "centered on the current
    /// locator" both anchor to (design-roadmap.md §6.6.1/§6.6.2).
    var currentWordLocator: Locator? {
        wordSegment(at: currentIndex)?.locator
    }

    private func wordSegment(at index: Int) -> TextContentElement.Segment? {
        guard let currentStream, currentStream.words.indices.contains(index) else { return nil }
        return currentStream.words[index]
    }

    // MARK: - Loading

    func load() async {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).rsvp
        theme = book.effectiveTheme(appSettings)

        do {
            let fileURL = try fileStorage.absoluteURL(forRelativePath: book.relativeFilePath)
            let publication = try await publicationLoader.open(fileURL: fileURL)
            self.publication = publication

            guard let resolved = await book.currentRSVPIndex(publication: publication, cache: wordStreamCache) else {
                loadState = .failed("Couldn't find a starting position in this book.")
                return
            }
            currentStream = resolved.stream
            currentIndex = resolved.index
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Re-reads this book's *current* effective theme/settings — called
    /// after the settings sheet is dismissed. `ConfigurationView` writes
    /// directly to the same `book`/`AppSettings` this view model already
    /// holds (same `modelContext`), but `theme`/`settings` here were only
    /// captured once, at `load()` time, so without this a change made
    /// mid-session silently wouldn't take effect until the mode was closed
    /// and reopened. `theme` is read directly by the view on every render,
    /// so updating it is enough to repaint; `settings` (WPM, smart timing,
    /// skip increments) is read fresh on every `delayForCurrentWord()`
    /// call, so playback picks it up on the very next word.
    func refreshSettings() {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).rsvp
        theme = book.effectiveTheme(appSettings)
    }

    // MARK: - Playback

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        // Resuming playback returns to the immersive view — the toolbar
        // isn't given an explicit close affordance in the spec, so hiding
        // it here (the mirror of "opening the toolbar also pauses") is the
        // natural read of the intended behavior. The BTR tooltip is the
        // same kind of transient overlay, so it's cleared the same way.
        isShowingToolbar = false
        isShowingBTRTooltip = false
        schedulePlayback()
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Tapping outside the word shows the toolbar and pauses, even if it
    /// was already paused (design-roadmap.md §6.3).
    func showToolbar() {
        pause()
        isShowingToolbar = true
        isShowingBTRTooltip = false
    }

    /// Long-pressing the current word shows the BTR tooltip and pauses,
    /// mirroring `showToolbar()`'s identical "any interaction with the
    /// word pauses" rule (design-roadmap.md §6.6.1).
    func showBTRTooltip() {
        pause()
        isShowingBTRTooltip = true
    }

    /// Builds a fresh `BTRMenuViewModel` anchored at the current word, or
    /// `nil` if there's nothing to anchor to yet (publication still
    /// loading) — the BTR icon shouldn't be reachable before `loadState ==
    /// .ready` in practice, but this stays defensive rather than assuming
    /// that ordering.
    func makeBTRMenuViewModel() -> BTRMenuViewModel? {
        guard let publication, let locator = currentWordLocator else { return nil }
        let appSettings = AppSettingsStore.current(in: modelContext)
        let provider = AIProviderFactory.makeProvider(settings: appSettings, keyStore: AppSettings.keyStore)
        return BTRMenuViewModel(
            book: book, publication: publication, anchorLocator: locator, provider: provider,
            enabledFeatures: BTRMenuViewModel.enabledMenuFeatures(for: book, modelContext: modelContext),
            modelContext: modelContext)
    }

    private func schedulePlayback() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                let delay = self.delayForCurrentWord()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, self.isPlaying else { return }

                let beforeHref = self.currentStream?.resourceHref
                let beforeIndex = self.currentIndex
                await self.step(by: 1)

                let madeNoProgress = self.currentStream?.resourceHref == beforeHref && self.currentIndex == beforeIndex
                if madeNoProgress {
                    // Genuinely at the end of the book.
                    self.pause()
                }
            }
        }
    }

    private func delayForCurrentWord() -> TimeInterval {
        guard let segment = wordSegment(at: currentIndex) else { return 0.3 }
        return RSVPTiming.delay(forWord: segment.text, after: segment.locator.text.after, settings: settings)
    }

    // MARK: - Position / seeking

    /// Moves by `delta` words, crossing into the next/previous resource's
    /// `WordStream` as needed. If it runs off either end of the book, it
    /// clamps at the boundary rather than going out of bounds.
    func step(by delta: Int) async {
        guard var stream = currentStream, let publication else { return }
        var index = currentIndex + delta
        var crossings = 0

        while index < 0 || index >= stream.words.count, crossings < Self.maxResourceCrossings {
            crossings += 1

            if index >= stream.words.count {
                guard
                    let nextHref = PublicationReadingOrder.adjacentResourceHref(
                        after: stream.resourceHref, in: publication, forward: true),
                    let nextStream = await wordStreamCache.stream(for: nextHref, in: publication),
                    !nextStream.words.isEmpty
                else {
                    index = max(stream.words.count - 1, 0)
                    break
                }
                index -= stream.words.count
                stream = nextStream
            } else {
                guard
                    let previousHref = PublicationReadingOrder.adjacentResourceHref(
                        after: stream.resourceHref, in: publication, forward: false),
                    let previousStream = await wordStreamCache.stream(for: previousHref, in: publication),
                    !previousStream.words.isEmpty
                else {
                    index = 0
                    break
                }
                index += previousStream.words.count
                stream = previousStream
            }
        }

        currentStream = stream
        currentIndex = index
        persistPosition()
    }

    /// Called by the word scrubber when the user scrolls it directly.
    func selectWordIndex(_ index: Int) {
        guard let currentStream, currentStream.words.indices.contains(index) else { return }
        currentIndex = index
        persistPosition()
    }

    /// Called by the chapter picker.
    func selectChapter(_ locator: Locator) async {
        guard let publication else { return }
        book.updatePosition(from: locator)
        guard let resolved = await book.currentRSVPIndex(publication: publication, cache: wordStreamCache) else {
            return
        }
        currentStream = resolved.stream
        currentIndex = resolved.index
    }

    private func persistPosition() {
        guard let segment = wordSegment(at: currentIndex) else { return }
        book.updatePosition(from: segment.locator)
        try? modelContext.save()
    }

}
