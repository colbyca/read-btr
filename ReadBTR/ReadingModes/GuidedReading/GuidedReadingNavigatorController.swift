import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit
import WebKit

/// UIKit bridge hosting Readium's `EPUBNavigatorViewController` for Guided
/// Reading (design-roadmap.md §6.4) — mirrors the child-view-controller
/// hosting pattern proven in the phase-2 spike
/// (`ReadiumNavigatorSpikeView.swift`).
///
/// Readium's own `Decoration` API is only used indirectly here — line
/// highlighting and auto-scroll are owned entirely by
/// `GuidedReadingHighlighter.js`, injected via `setupUserScripts`. Real
/// visual-line boundaries only exist once text is laid out at a specific
/// font size/width (dev.md §4.3), so they're computed live off the
/// rendered DOM (`Range.getClientRects()`, the same primitive Readium's own
/// decorator.js uses) rather than approximated from sentence/phrase
/// tokenization ahead of time. Readium's own navigation (`go(to:)`) is kept
/// for coarse, whole-resource jumps — chapter select, crossing into the
/// next resource — where its own Locator resolution is exactly the right
/// tool; it's only the fine-grained "which line, right now" layer that's
/// custom.
final class GuidedReadingNavigatorController: UIViewController {
    private static let messageHandlerName = "guidedReading"

    let navigator: EPUBNavigatorViewController

    /// Fired whenever the navigator's own position changes — from user
    /// scrolling (including our own JS-driven `scrollToLine`, which
    /// Readium's `EPUBSpreadView` tracks via the WebView's own
    /// `UIScrollViewDelegate`, indistinguishably from a manual scroll), a
    /// programmatic `go(to:)`, or initial load.
    var onLocationChange: ((Locator) -> Void)?

    /// Fired on every tap, reporting whether it landed on the current
    /// highlighted line (design-roadmap.md §6.4's "tap the highlighted
    /// text" play/pause trigger) or elsewhere ("tap outside" toolbar
    /// trigger) — computed entirely in JS against our own highlight
    /// overlay's rect, not Readium's decoration-activation events.
    var onLineTap: ((Bool) -> Void)?

    /// Fired whenever the reader long-presses/drags to select text, with
    /// the OS's own edit menu suppressed (design-roadmap.md §6.6.1: "while
    /// paused, long-press a word → the same tooltip [as RSVP], plus drag-
    /// handles... Readium's `SelectableNavigator` interface") — drives the
    /// shared `BTRSelectionTooltip` positioned at `Selection.frame` instead
    /// of the native `UIMenuController`/`UIEditMenuInteraction`, per
    /// `SelectableNavigatorDelegate`'s own documented pattern for a custom
    /// selection pop-up.
    var onSelectionAvailable: ((Selection) -> Void)?

    /// Fired exactly once, the first time this view has a real, non-zero
    /// size — i.e. once SwiftUI has actually mounted
    /// `GuidedReadingNavigatorRepresentable` into the live hierarchy and
    /// assigned it real layout, not merely once `init` has returned. Line
    /// rects are meaningless before that (dev.md §4.3: real line boundaries
    /// only exist once text is laid out at a specific width) — computing
    /// them any earlier would measure against a stale/zero frame.
    var onViewReady: (() -> Void)?

    /// Fired on every *subsequent* size change after the first (rotation,
    /// window resize) — previously computed line rects are stale once the
    /// viewport width changes, so callers should recompute.
    var onViewResized: (() -> Void)?

    private weak var registeredUserContentController: WKUserContentController?
    private var hasReportedReady = false
    private var lastReportedSize: CGSize = .zero

    init(publication: Publication, initialLocation: Locator?, theme: ReaderTheme) throws {
        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: Self.configuration(theme: theme)
        )
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        registeredUserContentController?.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        navigator.view.frame = view.bounds

        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        if !hasReportedReady {
            hasReportedReady = true
            lastReportedSize = size
            onViewReady?()
        } else if size != lastReportedSize {
            lastReportedSize = size
            onViewResized?()
        }
    }

    // MARK: - Line bridge (GuidedReadingHighlighter.js)

    /// Recomputes the line inventory for whatever resource is currently
    /// loaded and returns how many lines it found. `0` can mean either "not
    /// finished loading yet" or "this resource genuinely has no text" (e.g.
    /// alice.epub's cover-image wrapper page) — callers that need to tell
    /// those apart do so themselves (`GuidedReadingViewModel` uses
    /// `WordStream` to check emptiness ahead of navigating there at all).
    func refreshLines() async -> Int {
        intValue(from: await navigator.evaluateJavaScript("window.__guidedReading.refreshLines()"))
    }

    func lineText(at index: Int) async -> String? {
        guard case .success(let value) = await navigator.evaluateJavaScript("window.__guidedReading.lineText(\(index))")
        else {
            return nil
        }
        return value as? String
    }

    /// Highlights `index` as the current line, replacing any previous
    /// highlight. `tintHex`/`isActive` mirror `ReaderTheme.highlightColorHex`
    /// and playback state respectively (design-roadmap.md §6.4: "highlight
    /// color and play/pause color are both theme-driven").
    func highlightLine(_ index: Int, tintHex: String, isActive: Bool) async {
        let script = "window.__guidedReading.highlightLine(\(index), '\(jsStringLiteral(tintHex))', \(isActive))"
        _ = await navigator.evaluateJavaScript(script)
    }

    func clearHighlight() async {
        _ = await navigator.evaluateJavaScript("window.__guidedReading.clearHighlight()")
    }

    @discardableResult
    func scrollToLine(_ index: Int, animated: Bool) async -> Bool {
        let script = "window.__guidedReading.scrollToLine(\(index), \(animated))"
        if case .success = await navigator.evaluateJavaScript(script) {
            return true
        }
        return false
    }

    /// The line nearest the anchor position the WebView is scrolled to
    /// right now — used both to resolve a starting line after a coarse
    /// `go(to:)` jump, and to keep the highlight following along while the
    /// user manually scrolls, paused (design-roadmap.md §6.4).
    func currentVisibleLineIndex() async -> Int? {
        let index = intValue(
            from: await navigator.evaluateJavaScript("window.__guidedReading.currentVisibleLineIndex()"))
        return index >= 0 ? index : nil
    }

    @discardableResult
    func go(to locator: Locator, animated: Bool) async -> Bool {
        await navigator.go(to: locator, options: NavigatorGoOptions(animated: animated))
    }

    /// Pushes an updated theme to an *already-running* navigator —
    /// `Configuration(preferences:)` only sets the theme once, at
    /// construction time, so a settings change made mid-session (design-
    /// roadmap.md §6.2's per-book entry point) needs this to actually take
    /// effect without tearing down and recreating the navigator. Changing
    /// font/size/margins reflows the whole page, which invalidates any
    /// previously computed line rects — callers are responsible for
    /// recomputing them afterward (`GuidedReadingViewModel.refreshSettings`
    /// does, the same way a rotation/window-resize already has to).
    func applyTheme(_ theme: ReaderTheme) {
        navigator.submitPreferences(EPUBThemePreferences.make(for: theme, scroll: true))
    }

    func clearSelection() {
        navigator.clearSelection()
    }

    /// Debug-only: reports back the current highlight element's own
    /// rendered rect/style and the line data it was drawn from, as a raw
    /// JSON string — see `GuidedReadingHighlighter.js`'s `debugSnapshot`.
    func debugHighlightSnapshot() async -> String? {
        guard case .success(let value) = await navigator.evaluateJavaScript("window.__guidedReading.debugSnapshot()")
        else {
            return nil
        }
        return value as? String
    }

    private func intValue(from result: Result<Any, Error>) -> Int {
        guard case .success(let value) = result, let number = value as? NSNumber else { return 0 }
        return number.intValue
    }

    /// `tintHex` is always one of this app's own `ReaderTheme` hex strings,
    /// never user-typed free text, but this still escapes defensively
    /// rather than trusting that invariant to hold forever.
    private func jsStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// `scroll: true` isn't cosmetic — continuous scroll is what makes both
    /// our own line-to-line auto-scroll and manual paused-scroll work.
    /// Theme mapping itself lives in `EPUBThemePreferences`, shared with
    /// Normal reading mode.
    private static func configuration(theme: ReaderTheme) -> EPUBNavigatorViewController.Configuration {
        EPUBNavigatorViewController.Configuration(preferences: EPUBThemePreferences.make(for: theme, scroll: true))
    }
}

extension GuidedReadingNavigatorController: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChange?(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        // No dedicated UI surface for navigator-level errors yet — the only
        // case today (`.copyForbidden`) is DRM-only, out of scope per
        // dev.md §4.6. Acceptable to no-op for MVP.
    }

    /// Returning `false` here is the whole trick (documented directly on
    /// `SelectableNavigatorDelegate`): it suppresses the native OS edit
    /// menu for this selection, and `onSelectionAvailable` hands the
    /// `Selection` (locator + on-screen frame) up to
    /// `GuidedReadingViewModel` to draw the shared `BTRSelectionTooltip`
    /// instead.
    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        onSelectionAvailable?(selection)
        return false
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController
    ) {
        // `WKUserContentController.add(_:name:)` retains its handler
        // strongly, which would otherwise cycle back through
        // navigator.view → userContentController → self → navigator. The
        // weak proxy breaks that; `deinit`'s explicit removal is a belt-
        // and-suspenders cleanup on top of it, not a substitute for it.
        userContentController.add(WeakScriptMessageHandler(target: self), name: Self.messageHandlerName)
        registeredUserContentController = userContentController

        let script = WKUserScript(
            source: Self.injectedJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(script)
    }

    private static let injectedJavaScript: String = {
        guard
            let url = Bundle.main.url(forResource: "GuidedReadingHighlighter", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("GuidedReadingHighlighter.js missing from the app bundle")
            return ""
        }
        return source
    }()
}

extension GuidedReadingNavigatorController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == Self.messageHandlerName,
            let body = message.body as? [String: Any],
            body["type"] as? String == "tap"
        else {
            return
        }
        onLineTap?(body["onHighlight"] as? Bool ?? false)
    }
}

/// Breaks the strong retain cycle `WKUserContentController.add(_:name:)`
/// would otherwise create between the content controller and its handler.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
