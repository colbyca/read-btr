import Foundation
import ReadiumNavigator
@preconcurrency import ReadiumShared

/// Where the page on screen *ends*, for a BTR chat opened from the reader
/// controls with no selection: its context is the visible page plus
/// everything before it (design-roadmap.md §6.6).
///
/// Readium's own `currentLocation` points at the *top* of the page (its
/// progression is where the viewport starts), so text on the rest of the
/// page would be left out. This asks the page's web view how far through
/// the resource the viewport's far edge is — horizontally for the
/// paginated layout's columns, vertically when scrolling — and moves the
/// locator's progression there.
enum VisiblePageLocator {
    /// Fraction of the resource up to the viewport's far edge, 0...1.
    static let endProgressionScript = """
        (function() {
          var se = document.scrollingElement || document.documentElement;
          var vw = window.innerWidth, vh = window.innerHeight;
          if (se.scrollWidth > vw + 1) {
            return Math.min(1, (Math.abs(se.scrollLeft) + vw) / se.scrollWidth);
          }
          if (se.scrollHeight > vh + 1) {
            return Math.min(1, (se.scrollTop + vh) / se.scrollHeight);
          }
          return 1;
        })()
        """

    /// The end of the page currently on screen, or nil if the navigator
    /// has no position yet. Falls back to the top of the page if the web
    /// view can't be asked, which only ever leaves text out, never adds
    /// text the reader hasn't reached.
    @MainActor
    static func endOfVisiblePage(in navigator: EPUBNavigatorViewController) async -> Locator? {
        guard let current = navigator.currentLocation else { return nil }
        guard case .success(let value) = await navigator.evaluateJavaScript(endProgressionScript),
            let end = (value as? NSNumber)?.doubleValue
        else { return pageLocator(from: current, endProgression: nil) }
        return pageLocator(from: current, endProgression: end)
    }

    /// `locator` moved forward to `endProgression` (never backward), with
    /// any text context dropped: a page anchor isn't a selection.
    static func pageLocator(from locator: Locator, endProgression: Double?) -> Locator {
        let start = locator.locations.progression ?? 0
        let end = min(max(endProgression ?? start, start), 1)
        return locator.copy(
            locations: { $0.progression = end },
            text: { $0 = Locator.Text() })
    }
}
