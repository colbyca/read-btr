import SwiftUI

/// Thin `UIViewControllerRepresentable` wrapper so SwiftUI can host
/// `GuidedReadingNavigatorController` — mirrors the hosting pattern proven
/// in the phase-2 spike (`ReadiumNavigatorSpikeView.swift`), now used for
/// real Guided Reading (design-roadmap.md §6.4). `host` is constructed and
/// owned by `GuidedReadingViewModel`, not this view, so it survives view
/// identity churn (e.g. toolbar show/hide) without losing navigator state.
struct GuidedReadingNavigatorRepresentable: UIViewControllerRepresentable {
    let host: GuidedReadingNavigatorController

    func makeUIViewController(context: Context) -> GuidedReadingNavigatorController {
        host
    }

    func updateUIViewController(_ uiViewController: GuidedReadingNavigatorController, context: Context) {}
}
