import Foundation
import Observation
import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData

/// Drives the Guided Reading screen (design-roadmap.md §6.4): loads the
/// publication, wires up Readium's `EPUBNavigatorViewController` (via
/// `GuidedReadingNavigatorController`) for real EPUB rendering, and owns
/// line-by-line playback/highlighting from there. `@MainActor`, matching
/// the concurrency convention every other reading-mode view model already
/// uses.
///
/// "Segment" always means a real, currently-rendered on-screen *line*
/// (`GuidedReadingNavigatorController.refreshLines()`, backed by
/// `GuidedReadingHighlighter.js`'s `Range.getClientRects()`) — not a
/// sentence/phrase approximated ahead of time, so line boundaries are
/// recomputed per resource rather than built from Content API text up
/// front.
@MainActor
@Observable
final class GuidedReadingViewModel {
    enum LoadState: Equatable {
        case loading
        case failed(String)
        case ready
    }

    let book: Book

    private(set) var loadState: LoadState = .loading
    private(set) var navigatorHost: GuidedReadingNavigatorController?
    private(set) var currentLineIndex = -1
    private(set) var lineCount = 0
    private(set) var theme: ReaderTheme = .default
    private(set) var publication: Publication?

    var isPlaying = false
    var isShowingToolbar = false
    var isShowingChapterSelect = false
    var isShowingSettings = false

    /// BTR activation state (design-roadmap.md §6.6.1): a paused, active
    /// text selection drives the shared `BTRSelectionTooltip`, positioned
    /// at `currentSelection.frame`. `nil` selection = tooltip hidden.
    private(set) var currentSelection: Selection?
    var isShowingDictionary = false
    var isShowingSurroundingView = false
    var isShowingBTRMenu = false

    /// Selecting more than one word swaps the tooltip's Define action for
    /// Save Quote (design-roadmap.md §6.6.1).
    var selectionSpansMultipleWords: Bool {
        let wordCount = currentSelection?.locator.text.highlight?.split(whereSeparator: \.isWhitespace).count ?? 0
        return wordCount > 1
    }

    private let modelContext: ModelContext
    private let fileStorage: BookFileStorage
    private let publicationLoader: PublicationLoader
    private var settings: GuidedReadingSettings = .default
    private var playbackTask: Task<Void, Never>?

    /// The resource the navigator is currently showing — tracked locally
    /// rather than re-derived from `book.currentLocator` on demand, since
    /// that's only guaranteed fresh once `handleLocationChange` has had a
    /// chance to run after a scroll (design-roadmap.md §4.4's locator
    /// round-trip notes apply the same caution here).
    private var currentResourceHref = ""

    /// How many times `load()`/`advance()` will poll for the WebView to
    /// finish laying out a freshly-navigated resource before giving up —
    /// there's no officially exposed "content ready" signal
    /// (`evaluateJavaScript` just fails with `.spreadNotLoaded` until then,
    /// confirmed against swift-toolkit 3.11.0), so this polls rather than
    /// trusting a fixed delay.
    private static let lineReadyPollAttempts = 20
    private static let lineReadyPollDelayNanoseconds: UInt64 = 100_000_000

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

    // MARK: - Loading

    func load() async {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).guidedReading
        theme = book.effectiveTheme(appSettings)

        do {
            let fileURL = try fileStorage.absoluteURL(forRelativePath: book.relativeFilePath)
            let publication = try await publicationLoader.open(fileURL: fileURL)
            self.publication = publication

            guard let initialLocator = await firstReadableLocator(in: publication) else {
                // No navigator exists yet at this point, so there's no
                // toolbar to reveal — GuidedReadingScreen falls back to a
                // bare failure view (with its own implicit dismiss via the
                // system back/close chrome) when `navigatorHost` is nil.
                loadState = .failed("Couldn't find a starting position in this book.")
                return
            }
            currentResourceHref = initialLocator.href.string

            let host = try GuidedReadingNavigatorController(
                publication: publication,
                initialLocation: initialLocator,
                theme: theme
            )
            wireNavigatorCallbacks(host)
            navigatorHost = host
            // `loadState` deliberately stays `.loading` here — line rects
            // are meaningless before the navigator's view has a real,
            // final on-screen size (dev.md §4.3), which only happens once
            // SwiftUI actually mounts `GuidedReadingNavigatorRepresentable`
            // into the live hierarchy. `host.onViewReady`, wired above,
            // takes this the rest of the way to `.ready`.
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Runs once the navigator's view has a real size (`onViewReady`) —
    /// the earliest point at which line rects mean anything.
    private func finishLoadingOnceViewIsReady() async {
        guard let navigatorHost, loadState != .ready else { return }

        let count = await awaitLinesReady(navigatorHost)
        guard count > 0 else {
            loadState = .failed("Couldn't find a starting position in this book.")
            return
        }
        lineCount = count
        currentLineIndex = await navigatorHost.currentVisibleLineIndex() ?? 0
        await navigatorHost.highlightLine(currentLineIndex, tintHex: theme.highlightColorHex, isActive: isPlaying)
        loadState = .ready

        if let locator = book.currentLocator {
            persistPosition(correctedFrom: locator)
        }
    }

    /// Runs on every size change *after* the first (`onViewResized`) —
    /// rotation or a window resize invalidates previously computed line
    /// rects, so this rebuilds them and re-anchors the highlight as close
    /// as possible to where it was.
    private func refreshLinesAfterResize() async {
        guard loadState == .ready else { return }
        await recomputeLinesAndReanchorHighlight()
    }

    /// Re-reads this book's *current* effective theme/settings and pushes
    /// the theme to the already-running navigator — called after the
    /// settings sheet is dismissed. `ConfigurationView` writes directly to
    /// the same `book`/`AppSettings` this view model already holds (same
    /// `modelContext`), but `theme`/`settings` here were only captured
    /// once, at `load()` time, so without this a change made mid-session
    /// silently wouldn't take effect until the mode was closed and
    /// reopened. Font/size/margin changes reflow the whole page, which is
    /// why this also recomputes line rects and re-anchors the highlight
    /// afterward, the same as a rotation/window-resize already has to.
    func refreshSettings() async {
        let appSettings = AppSettingsStore.current(in: modelContext)
        settings = book.effectiveReaderSettings(appSettings).guidedReading
        theme = book.effectiveTheme(appSettings)

        guard let navigatorHost, loadState == .ready else { return }
        navigatorHost.applyTheme(theme)
        await recomputeLinesAndReanchorHighlight()
    }

    /// Shared by `refreshLinesAfterResize()` and `refreshSettings()`: waits
    /// for the (now-stale) line rects to be recomputable, resolves the
    /// line nearest where the highlight used to be, and re-applies both
    /// the highlight and the corrected saved position.
    private func recomputeLinesAndReanchorHighlight() async {
        guard let navigatorHost else { return }

        let count = await awaitLinesReady(navigatorHost)
        guard count > 0 else { return }
        lineCount = count
        let resolved = await navigatorHost.currentVisibleLineIndex() ?? currentLineIndex
        currentLineIndex = min(max(resolved, 0), count - 1)
        await navigatorHost.highlightLine(currentLineIndex, tintHex: theme.highlightColorHex, isActive: isPlaying)

        if let locator = book.currentLocator {
            persistPosition(correctedFrom: locator)
        }
    }

    /// `book.currentLocator`'s resource may have no extractable text at all
    /// (e.g. alice.epub's cover-image wrapper page, confirmed empirically)
    /// — a case the WebView can't distinguish from "still loading" on its
    /// own. Reuses `WordStream`/`WordStreamCache`'s existing, already-tested
    /// emptiness check and forward-walk purely as a cheap oracle here; RSVP
    /// still owns those types for its own word-stepping, this is a
    /// throwaway, unrelated cache instance.
    private func firstReadableLocator(in publication: Publication) async -> Locator? {
        guard let locator = book.currentLocator else { return nil }
        let probe = WordStreamCache()
        guard let stream = await probe.stream(for: locator.href.string, in: publication) else { return nil }
        if !stream.words.isEmpty {
            return locator
        }
        return await firstReadableLocator(from: stream.resourceHref, in: publication, probe: probe)
    }

    private func firstReadableLocator(
        from href: String,
        in publication: Publication,
        probe: WordStreamCache
    ) async -> Locator? {
        guard
            let nonEmpty = await probe.firstNonEmptyStream(from: href, in: publication),
            let link = publication.readingOrder.first(where: { $0.url().string == nonEmpty.resourceHref })
        else {
            return nil
        }
        return await publication.locate(link)
    }

    private func wireNavigatorCallbacks(_ host: GuidedReadingNavigatorController) {
        host.onLocationChange = { [weak self] locator in
            Task { @MainActor [weak self] in
                await self?.handleLocationChange(locator)
            }
        }
        host.onLineTap = { [weak self] onHighlight in
            if onHighlight {
                self?.togglePlayPause()
            } else {
                self?.showToolbar()
            }
        }
        host.onSelectionAvailable = { [weak self] selection in
            // "While paused" (design-roadmap.md §6.6.1) — a selection
            // firing while playing (WebKit's own long-press/drag gesture
            // doesn't know about our playback state) is simply ignored
            // rather than disabling text selection via injected CSS.
            guard let self, !self.isPlaying else { return }
            self.currentSelection = selection
        }
        host.onViewReady = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.finishLoadingOnceViewIsReady()
            }
        }
        host.onViewResized = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshLinesAfterResize()
            }
        }
    }

    /// Polls `refreshLines()` until it reports real content or attempts run
    /// out — see `lineReadyPollAttempts`'s doc comment.
    private func awaitLinesReady(_ host: GuidedReadingNavigatorController) async -> Int {
        for _ in 0..<Self.lineReadyPollAttempts {
            let count = await host.refreshLines()
            if count > 0 { return count }
            try? await Task.sleep(nanoseconds: Self.lineReadyPollDelayNanoseconds)
        }
        return 0
    }

    // MARK: - Playback

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying, currentLineIndex >= 0 else { return }
        isPlaying = true
        // Resuming playback returns to the immersive view — mirrors RSVP's
        // identical rule (RSVPViewModel.play). A stale selection/tooltip
        // from before playback resumed doesn't make sense mid-animation
        // either, so it's cleared the same way.
        isShowingToolbar = false
        dismissSelection()
        refreshHighlight()
        schedulePlayback()
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        refreshHighlight()
    }

    /// Tapping outside the highlighted line shows the toolbar and pauses,
    /// even if it was already paused (design-roadmap.md §6.4, mirroring
    /// RSVP's identical rule, §6.3).
    func showToolbar() {
        pause()
        isShowingToolbar = true
        dismissSelection()
    }

    /// Clears both the tooltip's own state and the navigator's underlying
    /// text selection — leaving one without the other would either show a
    /// tooltip with nothing selected, or leave a lingering visual selection
    /// with no tooltip over it.
    func dismissSelection() {
        currentSelection = nil
        navigatorHost?.clearSelection()
    }

    // MARK: - BTR (design-roadmap.md §6.6.1)

    /// Writes a `SavedQuote` for the current (necessarily multi-word)
    /// selection and dismisses the tooltip. Readium's `Selection` doesn't
    /// expose separate start/end locators, so both boundaries are the same
    /// selection locator — good enough given `SavedQuote.text` is the
    /// denormalized copy display actually reads from.
    func saveQuote() {
        guard let selection = currentSelection, let text = selection.locator.text.highlight else { return }
        let locatorJSON = (try? selection.locator.jsonString()) ?? ""
        let quote = SavedQuote(text: text, startLocatorJSON: locatorJSON, endLocatorJSON: locatorJSON, book: book)
        modelContext.insert(quote)
        try? modelContext.save()
        dismissSelection()
    }

    /// Builds a fresh `BTRMenuViewModel` anchored at the current selection,
    /// or `nil` if there's nothing selected (the BTR icon shouldn't be
    /// reachable without one in practice, but this stays defensive).
    func makeBTRMenuViewModel() -> BTRMenuViewModel? {
        guard let publication, let locator = currentSelection?.locator else { return nil }
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
                let delay = await self.delayForCurrentLine()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, self.isPlaying else { return }

                let beforeHref = self.currentResourceHref
                let beforeIndex = self.currentLineIndex
                await self.advance()

                let madeNoProgress = self.currentResourceHref == beforeHref && self.currentLineIndex == beforeIndex
                if madeNoProgress {
                    // Genuinely at the end of the book.
                    self.pause()
                }
            }
        }
    }

    private func delayForCurrentLine() async -> TimeInterval {
        guard let navigatorHost, let text = await navigatorHost.lineText(at: currentLineIndex) else { return 1.0 }
        let wordCount = max(text.split(whereSeparator: \.isWhitespace).count, 1)
        let wordsPerSecond = Double(max(settings.wordsPerMinute, 1)) / 60.0
        return Double(wordCount) / wordsPerSecond
    }

    // MARK: - Position / seeking

    /// Advances one line, crossing into the next resource as needed —
    /// mirrors `RSVPViewModel.step(by:)`'s resource-crossing shape, but
    /// forward-only (Guided Reading has no manual skip control; going
    /// backward while paused is the scroll gesture instead, §6.4) and also
    /// drives the navigator's own scroll to keep the new line on screen.
    private func advance() async {
        guard let navigatorHost, let publication else { return }

        if currentLineIndex + 1 < lineCount {
            currentLineIndex += 1
            await navigatorHost.highlightLine(currentLineIndex, tintHex: theme.highlightColorHex, isActive: isPlaying)
            await navigatorHost.scrollToLine(currentLineIndex, animated: true)
            // Persisted directly rather than waiting on the scroll's own
            // (debounced) `locationDidChange` — matches RSVP's
            // `step(by:)`, which also persists immediately after moving
            // rather than relying on an indirect signal.
            if let locator = book.currentLocator {
                persistPosition(correctedFrom: locator)
            }
            return
        }

        guard
            let nextHref = PublicationReadingOrder.adjacentResourceHref(
                after: currentResourceHref, in: publication, forward: true),
            let nextLocator = await firstReadableLocator(from: nextHref, in: publication, probe: WordStreamCache())
        else {
            // Genuinely at the end of the book — stay put.
            return
        }

        currentResourceHref = nextLocator.href.string
        _ = await navigatorHost.go(to: nextLocator, animated: false)

        let count = await awaitLinesReady(navigatorHost)
        guard count > 0 else { return }
        lineCount = count
        currentLineIndex = 0
        await navigatorHost.highlightLine(0, tintHex: theme.highlightColorHex, isActive: isPlaying)
        persistPosition(correctedFrom: nextLocator)
    }

    /// Called whenever the navigator's own position changes — from user
    /// scrolling (including our own JS-driven auto-scroll), a programmatic
    /// `go(to:)`, or initial load.
    private func handleLocationChange(_ locator: Locator) async {
        // While playing, `advance()` already owns which line is current and
        // has already applied its own highlight — recomputing here off
        // every intermediate scroll-settle callback would just fight it.
        // Only paused, user-driven scroll re-derives the current line
        // (design-roadmap.md §6.4: "while paused, vertical scroll moves
        // position... with the currently-decorated segment following
        // along").
        if !isPlaying, let navigatorHost {
            if locator.href.string != currentResourceHref {
                currentResourceHref = locator.href.string
                lineCount = await awaitLinesReady(navigatorHost)
            }
            if lineCount > 0, let index = await navigatorHost.currentVisibleLineIndex(), index != currentLineIndex {
                currentLineIndex = index
                await navigatorHost.highlightLine(index, tintHex: theme.highlightColorHex, isActive: isPlaying)
            }
        }

        // Persisted last, after any resync above, so this always reflects
        // whatever `currentLineIndex` actually is by now — not `advance()`'s
        // move (while playing) and not the resync just above (while paused).
        persistPosition(correctedFrom: locator)
    }

    /// Called by the chapter picker.
    func selectChapter(_ locator: Locator) async {
        guard let navigatorHost else { return }
        pause()
        currentResourceHref = locator.href.string

        _ = await navigatorHost.go(to: locator, animated: false)
        let count = await awaitLinesReady(navigatorHost)
        guard count > 0 else {
            // Couldn't resolve a line to correct against — persist the
            // chapter's own start locator verbatim rather than not
            // persisting anything at all.
            persistPosition(from: locator)
            return
        }

        lineCount = count
        currentLineIndex = await navigatorHost.currentVisibleLineIndex() ?? 0
        await navigatorHost.highlightLine(currentLineIndex, tintHex: theme.highlightColorHex, isActive: isPlaying)
        persistPosition(correctedFrom: locator)
    }

    /// Fire-and-forget wrapper for re-painting the highlight after a
    /// synchronous play/pause state change — the play/pause toggle itself
    /// stays synchronous (matching RSVP's API, and how the View calls it
    /// directly from tap handlers), only the JS round-trip that repaints
    /// its color runs asynchronously in the background.
    private func refreshHighlight() {
        guard currentLineIndex >= 0 else { return }
        let index = currentLineIndex
        let tintHex = theme.highlightColorHex
        let isActive = isPlaying
        Task { [weak navigatorHost] in
            await navigatorHost?.highlightLine(index, tintHex: tintHex, isActive: isActive)
        }
    }

    private func persistPosition(from locator: Locator) {
        book.updatePosition(from: locator)
        try? modelContext.save()
    }

    /// Persists `book.position` anchored to the *currently highlighted
    /// line*'s own progression, not wherever the navigator's raw scroll
    /// happens to be — auto-scroll deliberately leaves the highlighted line
    /// ~35% down the viewport (`GuidedReadingHighlighter.js`'s
    /// `ANCHOR_FRACTION`), so persisting that raw locator verbatim (as this
    /// used to do) undershoots the real reading position by about a third
    /// of a screen — this is what showed up as "RSVP and Guided Reading
    /// open to different spots" when switching modes mid-book.
    ///
    /// Keeps `fallback`'s `href`/`mediaType` but replaces `locations`
    /// wholesale (dropping any stale positional fragment, e.g.
    /// `cssSelector`), so downstream consumers — `RSVPPositionResolver`,
    /// Readium's own resolution when a mode is reopened — read purely off
    /// this corrected progression. Falls back to `fallback` verbatim if
    /// there's no definitive current line yet to correct against.
    private func persistPosition(correctedFrom fallback: Locator) {
        guard lineCount > 0, currentLineIndex >= 0 else {
            persistPosition(from: fallback)
            return
        }
        let progression = (Double(currentLineIndex) + 0.5) / Double(lineCount)
        let corrected = fallback.copy(locations: { $0 = Locator.Locations(progression: progression) })
        persistPosition(from: corrected)
    }
}
