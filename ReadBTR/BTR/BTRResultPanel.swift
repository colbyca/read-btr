import SwiftUI

/// The one shared "pending → result" panel both BTR options resolve into
/// (design-roadmap.md §6.6.3/§6.6.4: "one shared component, not two bespoke
/// implementations") — swaps a loading spinner for either the result text
/// or a failure message, keyed off `BTRResultState<String>`.
struct BTRResultPanel: View {
    let title: String?
    let state: BTRResultState<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("btr-result-title")
            }

            switch state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView()
                    .accessibilityIdentifier("btr-result-loading")
            case .result(let text):
                Text(text)
                    .accessibilityIdentifier("btr-result-text")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("btr-result-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
