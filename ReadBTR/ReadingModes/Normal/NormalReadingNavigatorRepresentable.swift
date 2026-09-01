import SwiftUI

/// Thin `UIViewControllerRepresentable` wrapper so SwiftUI can host
/// `NormalReadingNavigatorController` — same hosting pattern as
/// `GuidedReadingNavigatorRepresentable`. `host` is constructed and owned
/// by `NormalReadingViewModel`, not this view, so it survives view identity
/// churn (e.g. toolbar show/hide) without losing navigator state.
struct NormalReadingNavigatorRepresentable: UIViewControllerRepresentable {
    let host: NormalReadingNavigatorController

    func makeUIViewController(context: Context) -> NormalReadingNavigatorController {
        host
    }

    func updateUIViewController(_ uiViewController: NormalReadingNavigatorController, context: Context) {}
}
