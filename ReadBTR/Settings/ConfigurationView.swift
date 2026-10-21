import SwiftUI

/// The configuration page (design-roadmap.md §6.2) — one view, two entry
/// modes: `book == nil` edits `AppSettings` (global defaults, reached from
/// Home's settings icon); `book != nil` edits that book's own overrides
/// (reached from a reading mode's toolbar settings icon).
struct ConfigurationView: View {
    let book: Book?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ConfigurationViewModel?

    init(book: Book? = nil) {
        self.book = book
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    ConfigurationForm(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(book == nil ? "Settings" : "Book Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = ConfigurationViewModel(book: book, modelContext: modelContext)
        }
    }
}

private struct ConfigurationForm: View {
    @Bindable var viewModel: ConfigurationViewModel

    var body: some View {
        Form {
            ThemeSection(viewModel: viewModel)
            RSVPSettingsSection(viewModel: viewModel)
            GuidedReadingSettingsSection(viewModel: viewModel)
            NormalModeSettingsSection(viewModel: viewModel)
            AIProviderSection(viewModel: viewModel)
            AIFeaturesSection(viewModel: viewModel)
        }
    }
}

// MARK: - Reader theme (design-roadmap.md §2.4)

private struct ThemeSection: View {
    @Bindable var viewModel: ConfigurationViewModel

    /// A small curated set of iOS-bundled serif/humanist font families that
    /// read well for long-form text — `nil` (System Default) is always the
    /// first option.
    private static let fontChoices = ["Georgia", "Palatino", "Baskerville", "Avenir", "Times New Roman"]

    var body: some View {
        Section {
            ColorPicker("Background", selection: backgroundColor)
            ColorPicker("Text", selection: textColor)
            ColorPicker("Highlight", selection: highlightColor)

            Picker("Font", selection: fontName) {
                Text("System Default").tag(String?.none)
                ForEach(Self.fontChoices, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }

            LabeledSlider(
                label: "Font Size",
                value: fontSize,
                range: 12...32,
                step: 1,
                format: { "\(Int($0))pt" }
            )
            LabeledSlider(
                label: "Line Spacing",
                value: lineSpacing,
                range: 1.0...2.5,
                step: 0.1,
                format: { String(format: "%.1f×", $0) }
            )
            LabeledSlider(
                label: "Margins",
                value: margins,
                range: 0...48,
                step: 2,
                format: { "\(Int($0))pt" }
            )
        } header: {
            Text("Reader Theme")
        } footer: {
            if viewModel.isPerBook {
                OverrideFooter(isOverridden: viewModel.isThemeOverridden, reset: viewModel.resetTheme)
            }
        }
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Color(hex: viewModel.theme.backgroundColorHex) },
            set: { newValue in viewModel.updateTheme { $0.backgroundColorHex = newValue.hexString } }
        )
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { Color(hex: viewModel.theme.textColorHex) },
            set: { newValue in viewModel.updateTheme { $0.textColorHex = newValue.hexString } }
        )
    }

    private var highlightColor: Binding<Color> {
        Binding(
            get: { Color(hex: viewModel.theme.highlightColorHex) },
            set: { newValue in viewModel.updateTheme { $0.highlightColorHex = newValue.hexString } }
        )
    }

    private var fontName: Binding<String?> {
        Binding(
            get: { viewModel.theme.fontName },
            set: { newValue in viewModel.updateTheme { $0.fontName = newValue } }
        )
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { viewModel.theme.fontSize },
            set: { newValue in viewModel.updateTheme { $0.fontSize = newValue } }
        )
    }

    private var lineSpacing: Binding<Double> {
        Binding(
            get: { viewModel.theme.lineSpacing },
            set: { newValue in viewModel.updateTheme { $0.lineSpacing = newValue } }
        )
    }

    private var margins: Binding<Double> {
        Binding(
            get: { viewModel.theme.marginPoints },
            set: { newValue in viewModel.updateTheme { $0.marginPoints = newValue } }
        )
    }
}
