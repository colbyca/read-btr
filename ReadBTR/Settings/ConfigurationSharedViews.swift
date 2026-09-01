import SwiftUI

/// A slider paired with a leading label and its live-formatted value —
/// used by every numeric theme/pacing control in `ConfigurationView` so the
/// pattern (and its `.monospacedDigit()` alignment) is defined once.
struct LabeledSlider: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

/// Shown under any section backing a category-level per-book override
/// (theme, reader settings) — surfaces whether this book has its own copy
/// yet, and a way to drop back to the global default.
struct OverrideFooter: View {
    let isOverridden: Bool
    var overriddenText: String = "Customized for this book."
    let reset: () -> Void

    var body: some View {
        if isOverridden {
            VStack(alignment: .leading, spacing: 4) {
                Text(overriddenText)
                Button("Reset to Default", role: .destructive, action: reset)
            }
        } else {
            Text("Using the global default. Changing a setting here customizes it for this book only.")
        }
    }
}
