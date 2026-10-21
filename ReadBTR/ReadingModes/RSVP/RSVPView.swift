import SwiftUI

/// design-roadmap.md §6.3.
struct RSVPView: View {
    let book: Book

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: RSVPViewModel?

    var body: some View {
        Group {
            if let viewModel {
                RSVPReadingScreen(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil else { return }
            let model = RSVPViewModel(book: book, modelContext: modelContext)
            viewModel = model
            await model.load()
        }
    }
}

private struct RSVPReadingScreen: View {
    @Bindable var viewModel: RSVPViewModel
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
            NavigationStack {
                RSVPContentView(viewModel: viewModel)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(viewModel.isShowingToolbar ? .visible : .hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityIdentifier("rsvp-exit")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                viewModel.isShowingChapterSelect = true
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .accessibilityIdentifier("rsvp-chapter-select")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                viewModel.isShowingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityIdentifier("rsvp-settings")
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
                    .sheet(isPresented: $viewModel.isShowingDictionary) {
                        if let word = viewModel.currentWord {
                            DictionaryLookupView(term: word)
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
}

/// The immersive word display + tap targets + (when shown) the bottom
/// scrubber. Background and word color come from `book.effectiveTheme` —
/// the reader surface, deliberately independent of the app chrome's
/// Catppuccin palette (dev.md §10.2) — while the toolbar chrome itself uses
/// plain system colors.
private struct RSVPContentView: View {
    @Bindable var viewModel: RSVPViewModel

    var body: some View {
        ZStack {
            Color(hex: viewModel.theme.backgroundColorHex)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.showToolbar()
                }
                .accessibilityIdentifier("rsvp-background")

            if let word = viewModel.currentWord {
                Text(word)
                    .font(themeFont)
                    .foregroundStyle(
                        viewModel.isPlaying
                            ? Color(hex: viewModel.theme.textColorHex)
                            : Color(hex: viewModel.theme.highlightColorHex)
                    )
                    .padding(40)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.togglePlayPause()
                    }
                    .onLongPressGesture {
                        viewModel.showBTRTooltip()
                    }
                    .accessibilityIdentifier("rsvp-current-word")
                    .overlay(alignment: .bottom) {
                        if viewModel.isShowingBTRTooltip {
                            BTRSelectionTooltip(
                                onDefine: { viewModel.isShowingDictionary = true },
                                onViewSurrounding: { viewModel.isShowingSurroundingView = true },
                                onBTR: viewModel.isBTRAvailable ? { viewModel.isShowingBTRMenu = true } : nil
                            )
                            .offset(y: 64)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
            }

            VStack {
                Spacer()
                if viewModel.isShowingToolbar, let stream = viewModel.currentStream {
                    RSVPWordScrubber(
                        stream: stream,
                        currentIndex: viewModel.currentIndex,
                        onSelect: { viewModel.selectWordIndex($0) }
                    )
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.default, value: viewModel.isShowingToolbar)
    }

    /// RSVP's centered word is deliberately much larger than body reading
    /// text, so this doesn't scale 1:1 off `ReaderTheme.fontSize` — it just
    /// honors the chosen font family, at a fixed display-appropriate size.
    private var themeFont: Font {
        if let fontName = viewModel.theme.fontName {
            .custom(fontName, size: 40)
        } else {
            .system(size: 40, weight: .semibold)
        }
    }
}
