import SwiftUI

/// The BTR menu screen (design-roadmap.md §6.6.2): a vertical split — a
/// read-only preview of the book centered on the position the menu was
/// opened at, and a bottom "BTR options" panel (entity chips + "Summarize
/// since start of chapter"). Presented via `.fullScreenCover`/`.sheet` from
/// whichever reading mode's BTR icon triggered it; the back arrow just
/// `dismiss()`s — none of the three modes auto-resume playback on their
/// own dismiss handlers, so returning here leaves them exactly as paused as
/// they were (design-roadmap.md §6.6.2: "resuming paused if that mode was
/// paused").
struct BTRMenuView: View {
    @Bindable var viewModel: BTRMenuViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPane
                    .frame(maxHeight: .infinity)
                Divider()
                ScrollView {
                    optionsPanel
                        .padding()
                }
                .frame(maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityIdentifier("btr-menu-back")
                }
            }
            .task {
                viewModel.preparePreview()
                await viewModel.loadEntities()
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let host = viewModel.previewNavigatorHost {
            NormalReadingNavigatorRepresentable(host: host)
                .accessibilityIdentifier("btr-menu-preview")
        } else {
            Color(hex: viewModel.theme.backgroundColorHex)
                .accessibilityIdentifier("btr-menu-preview-unavailable")
        }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            entityChipsSection

            Button("Summarize Since Start of Chapter") {
                Task { await viewModel.summarizeChapter() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("btr-summarize-chapter")

            if viewModel.selectedOptionResult != .idle {
                Divider()
                BTRResultPanel(title: viewModel.selectedOptionTitle, state: viewModel.selectedOptionResult)
            }
        }
    }

    @ViewBuilder
    private var entityChipsSection: some View {
        switch viewModel.entitiesState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Finding characters & locations…")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .accessibilityIdentifier("btr-entities-loading")

        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .font(.footnote)
                .accessibilityIdentifier("btr-entities-error")

        case .result(let entities):
            if entities.isEmpty {
                Text("No characters or locations found nearby.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .accessibilityIdentifier("btr-entities-empty")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entities) { entity in
                            BTREntityChip(
                                entity: entity, isSelected: viewModel.selectedOptionTitle == entity.name
                            ) {
                                Task { await viewModel.selectEntity(entity) }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("btr-entities-list")
            }
        }
    }
}
