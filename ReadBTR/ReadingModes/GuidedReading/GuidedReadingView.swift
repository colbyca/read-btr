import SwiftUI

/// design-roadmap.md §6.4.
struct GuidedReadingView: View {
    let book: Book

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: GuidedReadingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                GuidedReadingScreen(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil else { return }
            let model = GuidedReadingViewModel(book: book, modelContext: modelContext)
            viewModel = model
            await model.load()
        }
    }
}

private struct GuidedReadingScreen: View {
    @Bindable var viewModel: GuidedReadingViewModel
    @Environment(\.dismiss) private var dismiss

    /// `HomeView` presents this via `.fullScreenCover`, which has no
    /// native swipe-to-dismiss — the exit button here is the *only* way
    /// out, so it must stay reachable in every non-`.ready` state: before
    /// a navigator exists (nothing to tap-to-reveal-the-toolbar on yet),
    /// while its view is mounted but still computing lines, or if loading
    /// fails outright. Once actually `.ready`, this defers back to the
    /// normal tap-to-show/hide behavior (design-roadmap.md §6.4).
    private var toolbarIsVisible: Bool {
        viewModel.loadState != .ready || viewModel.isShowingToolbar
    }

    var body: some View {
        NavigationStack {
            Group {
                if let host = viewModel.navigatorHost {
                    // Gated on `navigatorHost`, not `loadState` — unlike
                    // RSVP, `loadState` can only reach `.ready` *after*
                    // this navigator's view has actually been mounted and
                    // laid out (its `onViewReady` callback is what finishes
                    // loading). Switching it out of the tree during
                    // `.loading` would deadlock: the view never gets laid
                    // out because it's never mounted, and loading never
                    // finishes because the view never gets laid out.
                    GuidedReadingContentView(viewModel: viewModel, host: host)
                } else if case .failed(let message) = viewModel.loadState {
                    GuidedReadingFailureView(message: message)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(toolbarIsVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("guided-reading-exit")
                }
                if viewModel.navigatorHost != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.isShowingChapterSelect = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityIdentifier("guided-reading-chapter-select")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("guided-reading-settings")
                    }
                }
            }
            .sheet(isPresented: $viewModel.isShowingChapterSelect) {
                if let publication = viewModel.publication {
                    ChapterSelectSheet(publication: publication) { locator in
                        Task { await viewModel.selectChapter(locator) }
                    }
                }
            }
            .sheet(
                isPresented: $viewModel.isShowingSettings,
                onDismiss: { Task { await viewModel.refreshSettings() } }
            ) {
                ConfigurationView(book: viewModel.book)
            }
            .sheet(isPresented: $viewModel.isShowingDictionary) {
                if let term = viewModel.currentSelection?.locator.text.highlight {
                    DictionaryLookupView(term: term)
                }
            }
            .fullScreenCover(isPresented: $viewModel.isShowingSurroundingView) {
                NormalReadingView(book: viewModel.book, forcedLayout: .scrolling)
            }
            .fullScreenCover(isPresented: $viewModel.isShowingBTRMenu) {
                if let btrViewModel = viewModel.makeBTRMenuViewModel() {
                    BTRMenuView(viewModel: btrViewModel)
                }
            }
        }
    }
}

/// Hosts Readium's own EPUB navigator, full-bleed, with a loading/error
/// overlay drawn *on top* of it rather than replacing it in the view tree —
/// unlike RSVP's solid-color/plain-text surface, the navigator's own view
/// has to actually be on screen and laid out before `viewModel.loadState`
/// can ever leave `.loading` (design-roadmap.md §6.4), so it can't be
/// gated behind that same state the way RSVP's simpler content view is.
/// Tap-to-show-toolbar and tap-to-play/pause are both handled inside the
/// navigator's own UIKit/JS layer (`GuidedReadingNavigatorController` +
/// `GuidedReadingHighlighter.js`), not as a SwiftUI gesture overlay — a
/// transparent overlay on top of the WebView would swallow the scroll/tap
/// gestures that layer needs to see directly.
private struct GuidedReadingContentView: View {
    @Bindable var viewModel: GuidedReadingViewModel
    let host: GuidedReadingNavigatorController

    var body: some View {
        ZStack {
            GuidedReadingNavigatorRepresentable(host: host)
                .ignoresSafeArea()
                .accessibilityIdentifier("guided-reading-navigator")

            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .accessibilityIdentifier("guided-reading-loading")
            case .failed(let message):
                GuidedReadingFailureView(message: message)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .ready:
                EmptyView()
            }

            // Positioned at the selection's own on-screen frame (design-
            // roadmap.md §6.6.1) — `Selection.frame` is already in this
            // navigator view's coordinate space, which this `ZStack`
            // shares exactly (both full-bleed, `.ignoresSafeArea()`).
            if let selection = viewModel.currentSelection, let frame = selection.frame {
                BTRSelectionTooltip(
                    showsSaveQuote: viewModel.selectionSpansMultipleWords,
                    onDefine: { viewModel.isShowingDictionary = true },
                    onViewSurrounding: { viewModel.isShowingSurroundingView = true },
                    onSaveQuote: { viewModel.saveQuote() },
                    onBTR: viewModel.isBTRAvailable ? { viewModel.isShowingBTRMenu = true } : nil
                )
                .position(x: frame.midX, y: max(frame.minY - 40, 40))
                .transition(.opacity)
                .accessibilityIdentifier("guided-reading-selection-tooltip")
            }
        }
        .animation(.default, value: viewModel.currentSelection != nil)
    }
}

private struct GuidedReadingFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }
}
