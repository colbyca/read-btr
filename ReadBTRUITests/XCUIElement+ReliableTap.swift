import XCTest

extension XCUIElement {
    /// Taps this element's center coordinate directly, bypassing XCUITest's
    /// AX "scroll to visible" pathway. Plain `.tap()` on HomeView's toolbar
    /// `Menu` button reproducibly fails with a `kAXErrorCannotComplete`
    /// error in this environment (not a flake — confirmed across repeated
    /// runs); this sidesteps whatever AX-scroll heuristic is failing.
    func reliableTap() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
