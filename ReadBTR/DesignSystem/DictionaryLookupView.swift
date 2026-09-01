import SwiftUI
import UIKit

/// "Define" (design-roadmap.md §6.6.1) — the system "Look Up" panel, no
/// new dependency, offline (decided in the decision log, design-roadmap.md
/// §9). Shared across every activation site that needs its own custom
/// Define affordance (RSVP, Guided Reading) — Normal mode doesn't need
/// this, since its native text-selection menu already includes the
/// system's own Look Up action directly.
struct DictionaryLookupView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
