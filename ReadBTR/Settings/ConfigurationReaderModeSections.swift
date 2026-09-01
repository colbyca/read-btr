import SwiftUI

// MARK: - RSVP / Guided Reading / Normal (design-roadmap.md §2.5)
//
// These three sections all read/write the *same* category-level
// `ReaderSettings` override, so only the last one shows the
// override/reset footer — resetting there resets all three together,
// which the footer's own copy calls out explicitly.

struct RSVPSettingsSection: View {
    @Bindable var viewModel: ConfigurationViewModel

    var body: some View {
        Section {
            LabeledSlider(
                label: "Speed",
                value: wordsPerMinute,
                range: 100...800,
                step: 25,
                format: { "\(Int($0)) WPM" }
            )
            Toggle("Smart Timing", isOn: smartTimingEnabled)
            Stepper("Skip (small): \(viewModel.readerSettings.rsvp.skipIncrementSmall)", value: skipSmall, in: 1...50)
            Stepper(
                "Skip (medium): \(viewModel.readerSettings.rsvp.skipIncrementMedium)", value: skipMedium, in: 1...100)
            Stepper("Skip (large): \(viewModel.readerSettings.rsvp.skipIncrementLarge)", value: skipLarge, in: 1...200)
        } header: {
            Text("RSVP")
        }
    }

    private var wordsPerMinute: Binding<Double> {
        Binding(
            get: { Double(viewModel.readerSettings.rsvp.wordsPerMinute) },
            set: { newValue in viewModel.updateReaderSettings { $0.rsvp.wordsPerMinute = Int(newValue) } }
        )
    }

    private var smartTimingEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.readerSettings.rsvp.smartTimingEnabled },
            set: { newValue in viewModel.updateReaderSettings { $0.rsvp.smartTimingEnabled = newValue } }
        )
    }

    private var skipSmall: Binding<Int> {
        Binding(
            get: { viewModel.readerSettings.rsvp.skipIncrementSmall },
            set: { newValue in viewModel.updateReaderSettings { $0.rsvp.skipIncrementSmall = newValue } }
        )
    }

    private var skipMedium: Binding<Int> {
        Binding(
            get: { viewModel.readerSettings.rsvp.skipIncrementMedium },
            set: { newValue in viewModel.updateReaderSettings { $0.rsvp.skipIncrementMedium = newValue } }
        )
    }

    private var skipLarge: Binding<Int> {
        Binding(
            get: { viewModel.readerSettings.rsvp.skipIncrementLarge },
            set: { newValue in viewModel.updateReaderSettings { $0.rsvp.skipIncrementLarge = newValue } }
        )
    }
}

struct GuidedReadingSettingsSection: View {
    @Bindable var viewModel: ConfigurationViewModel

    var body: some View {
        Section {
            LabeledSlider(
                label: "Speed",
                value: wordsPerMinute,
                range: 100...800,
                step: 25,
                format: { "\(Int($0)) WPM" }
            )
        } header: {
            Text("Guided Reading")
        }
    }

    private var wordsPerMinute: Binding<Double> {
        Binding(
            get: { Double(viewModel.readerSettings.guidedReading.wordsPerMinute) },
            set: { newValue in viewModel.updateReaderSettings { $0.guidedReading.wordsPerMinute = Int(newValue) } }
        )
    }
}

struct NormalModeSettingsSection: View {
    @Bindable var viewModel: ConfigurationViewModel

    var body: some View {
        Section {
            Picker("Layout", selection: layout) {
                Text("Scrolling").tag(NormalModeLayout.scrolling)
                Text("Paginated").tag(NormalModeLayout.paginated)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Normal Reading")
        } footer: {
            if viewModel.isPerBook {
                OverrideFooter(
                    isOverridden: viewModel.isReaderSettingsOverridden,
                    overriddenText: "RSVP, Guided Reading, and Normal settings are customized together for this book.",
                    reset: viewModel.resetReaderSettings
                )
            }
        }
    }

    private var layout: Binding<NormalModeLayout> {
        Binding(
            get: { viewModel.readerSettings.normalMode.layout },
            set: { newValue in viewModel.updateReaderSettings { $0.normalMode.layout = newValue } }
        )
    }
}
