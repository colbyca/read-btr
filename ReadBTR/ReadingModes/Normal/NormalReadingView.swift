import SwiftUI

/// design-roadmap.md §6.5 — the simplest of the three reading-mode screens:
/// Readium's stock navigator, no custom highlighting/playback layer, so
/// there's no loading-vs-mounting race to resolve the way Guided Reading
/// needed — `loadState` reaches `.ready` synchronously once the
/// publication opens and the navigator constructs, without ever waiting on
/// the navigator's view being laid out first.
struct NormalReadingView: View {
    let book: Book

    /// Overrides the user's own Normal-mode layout preference — set by
    /// RSVP's "View Surrounding" (design-roadmap.md §6.6.1: "in scrolling
    /// mode"), `nil` everywhere else (Home's own mode picker).
    var forcedLayout: NormalModeLayout?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: NormalReadingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NormalReadingScreen(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil else { return }
            let model = NormalReadingViewModel(book: book, modelContext: modelContext, forcedLayout: forcedLayout)
            viewModel = model
            await model.load()
        }
    }
}

private struct NormalReadingScreen: View {
    @Bindable var viewModel: NormalReadingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView()

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

        case .ready:
            if let host = viewModel.navigatorHost {
                NavigationStack {
                    NormalReadingNavigatorRepresentable(host: host)
                        .ignoresSafeArea()
                        .accessibilityIdentifier("normal-reading-navigator")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(viewModel.isShowingToolbar ? .visible : .hidden, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityIdentifier("normal-reading-exit")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    viewModel.isShowingChapterSelect = true
                                } label: {
                                    Image(systemName: "list.bullet")
                                }
                                .accessibilityIdentifier("normal-reading-chapter-select")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    viewModel.isShowingSettings = true
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .accessibilityIdentifier("normal-reading-settings")
                            }
                        }
                        .sheet(isPresented: $viewModel.isShowingChapterSelect) {
                            if let publication = viewModel.publication {
                                ChapterSelectSheet(publication: publication) { locator in
                                    Task { await viewModel.selectChapter(locator) }
                                }
                            }
                        }
                        .sheet(isPresented: $viewModel.isShowingSettings, onDismiss: { viewModel.refreshSettings() }) {
                            ConfigurationView(book: viewModel.book)
                        }
                        .fullScreenCover(isPresented: $viewModel.isShowingBTRMenu) {
                            if let btrViewModel = viewModel.makeBTRMenuViewModel() {
                                BTRMenuView(viewModel: btrViewModel)
                            }
                        }
                        .quoteSavedToast(trigger: viewModel.quoteSavedConfirmationID)
                }
            }
        }
    }
}
