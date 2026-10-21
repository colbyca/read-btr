import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

/// UIKit bridge hosting Readium's own `EPUBNavigatorViewController` for
/// Normal reading (design-roadmap.md §6.5). Unlike Guided Reading, this is
/// intentionally *just* the stock navigator — no injected JS, no custom
/// highlighting/scroll layer, no line computation, no polling for the
/// WebView to lay out before anything can proceed (dev.md §4.2: Normal
/// mode needs no custom rendering at all). Scrolling vs. paginated is
/// Readium's own `EPUBPreferences.scroll` toggle, driven directly by
/// `NormalModeSettings.layout`.
final class NormalReadingNavigatorController: UIViewController {
    let navigator: EPUBNavigatorViewController

    /// Fired whenever the navigator's own position changes — from user
    /// scrolling/page-turning, a programmatic `go(to:)`, or initial load.
    var onLocationChange: ((Locator) -> Void)?

    /// Fired on a tap landing in the top strip of the screen — the one
    /// mode-specific toolbar trigger design-roadmap.md §6.5 calls for:
    /// "a tap at the top of the screen, not anywhere on the page."
    var onTopTap: (() -> Void)?

    /// Fired when the reader taps "BTR" in the native text-selection edit
    /// menu (design-roadmap.md §6.6.1: "native WebView text selection,
    /// with the same tooltip appended as a custom `EditingAction`") — the
    /// one activation mechanism that doesn't go through
    /// `BTRSelectionTooltip` at all, since Normal mode's selection UI is
    /// already the system's own.
    var onBTRRequested: ((Selection) -> Void)?

    /// Fired when the reader taps "Save Quote" in the same native edit
    /// menu — Normal mode's equivalent of Guided Reading's tooltip action.
    var onSaveQuoteRequested: ((Selection) -> Void)?

    /// Height of the tap-to-reveal-toolbar zone, in points, measured from
    /// the top of the navigator's own view.
    private static let topTapZoneHeight: CGFloat = 80

    /// `includesCustomActions` controls the "Save Quote" and "BTR" entries
    /// appended to the native selection edit menu. `false` only for the read-only preview pane `BTRMenuViewModel.preparePreview()`
    /// embeds inside the BTR menu itself — without this, selecting text
    /// there could open a second BTR menu on top of the first.
    init(
        publication: Publication, initialLocation: Locator?, theme: ReaderTheme, layout: NormalModeLayout,
        includesCustomActions: Bool = true
    ) throws {
        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: Self.configuration(theme: theme, layout: layout, includesCustomActions: includesCustomActions)
        )
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
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
    }

    @discardableResult
    func go(to locator: Locator, animated: Bool) async -> Bool {
        await navigator.go(to: locator, options: NavigatorGoOptions(animated: animated))
    }

    /// Pushes an updated theme/layout to an *already-running* navigator —
    /// `Configuration(preferences:)` only applies once, at construction
    /// time, so a settings change made mid-session (design-roadmap.md
    /// §6.2's per-book entry point) needs this to actually take effect.
    func applyTheme(_ theme: ReaderTheme, layout: NormalModeLayout) {
        navigator.submitPreferences(EPUBThemePreferences.make(for: theme, scroll: layout == .scrolling))
    }

    private static func configuration(
        theme: ReaderTheme,
        layout: NormalModeLayout,
        includesCustomActions: Bool
    ) -> EPUBNavigatorViewController.Configuration {
        var editingActions = EditingAction.defaultActions
        if includesCustomActions {
            editingActions.append(saveQuoteEditingAction)
            editingActions.append(btrEditingAction)
        }
        return EPUBNavigatorViewController.Configuration(
            preferences: EPUBThemePreferences.make(for: theme, scroll: layout == .scrolling),
            editingActions: editingActions
        )
    }

    /// A custom action needs its selector implemented on a class in the
    /// responder chain — this `UIViewController` (the one directly wrapping
    /// the navigator) is exactly that, per `EditingAction`'s own doc
    /// comment. Dispatched through `UIApplication.shared.sendAction` by
    /// `EditingActionsController`, not called directly.
    private static let btrEditingAction = EditingAction(
        title: "BTR", action: #selector(NormalReadingNavigatorController.triggerBTRAction))

    private static let saveQuoteEditingAction = EditingAction(
        title: "Save Quote", action: #selector(NormalReadingNavigatorController.triggerSaveQuoteAction))

    @objc private func triggerBTRAction() {
        guard let selection = navigator.currentSelection else { return }
        onBTRRequested?(selection)
    }

    @objc private func triggerSaveQuoteAction() {
        guard let selection = navigator.currentSelection else { return }
        onSaveQuoteRequested?(selection)
        navigator.clearSelection()
    }
}

extension NormalReadingNavigatorController: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChange?(locator)
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard point.y <= Self.topTapZoneHeight else { return }
        onTopTap?()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        // No dedicated UI surface for navigator-level errors yet — mirrors
        // GuidedReadingNavigatorController's identical no-op (dev.md §4.6:
        // the only case today, `.copyForbidden`, is DRM-only, out of scope).
    }
}
