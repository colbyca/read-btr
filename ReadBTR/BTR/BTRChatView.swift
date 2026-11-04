import SwiftUI

/// The BTR chat (design-roadmap.md §6.6.2): opened from any reading mode's
/// BTR entry point, it shows the passage the reader opened it from — the
/// word(s) they were on plus 10 words either side, each tappable to select
/// it as the focus of a question — and a chat about the book underneath.
/// Replies are Markdown, rendered by `MarkdownText`.
///
/// The back arrow just `dismiss()`es; none of the reading modes resume
/// playback on their own when it closes, so the reader comes back exactly
/// as paused as they left.
struct BTRChatView: View {
    @Bindable var viewModel: BTRChatViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    private static let suggestions = [
        "Summarize this chapter so far",
        "Who are the main characters so far?",
        "What does this passage mean?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                passageHeader
                Divider()
                conversation
                Divider()
                inputBar
            }
            .navigationTitle("BTR Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("btr-chat-back")
                }
            }
            .task {
                await viewModel.loadContextWords()
            }
        }
    }

    // MARK: - Passage

    private var passageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.contextWords.isEmpty {
                Text(viewModel.book.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(horizontalSpacing: 2, verticalSpacing: 4) {
                    ForEach(viewModel.contextWords) { word in
                        wordButton(word)
                    }
                }
                .accessibilityIdentifier("btr-chat-passage")

                Text(passageCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    private var passageCaption: String {
        var caption =
            viewModel.selectedWordIDs.isEmpty
            ? "Tap words to focus your question on them."
            : "Selected words are the focus of your question. Tap to change."
        if !viewModel.earlierBookTitles.isEmpty {
            let count = viewModel.earlierBookTitles.count
            caption += " Also drawing on \(count) earlier book\(count == 1 ? "" : "s") in this collection."
        }
        return caption
    }

    private func wordButton(_ word: BTRContextWord) -> some View {
        let isSelected = viewModel.selectedWordIDs.contains(word.id)
        return Button {
            viewModel.toggleWord(word)
        } label: {
            Text(word.text)
                .font(.callout)
                .fontWeight(word.isAnchor ? .semibold : .regular)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("btr-chat-word-\(word.id)")
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        BTRChatBubble(message: message) {
                            Task { await viewModel.retry(message) }
                        }
                        .id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask anything about the book. Answers only use what you've already read, so nothing ahead gets spoiled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button(suggestion) {
                    Task { await viewModel.ask(suggestion) }
                }
                .buttonStyle(.bordered)
                .font(.callout)
            }
        }
        .accessibilityIdentifier("btr-chat-empty")
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the book…", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit { Task { await viewModel.sendDraft() } }
                .accessibilityIdentifier("btr-chat-input")

            Button {
                Task { await viewModel.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("btr-chat-send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// One message: the reader's questions right-aligned, replies left-aligned
/// and rendered as Markdown.
private struct BTRChatBubble: View {
    let message: BTRChatMessage
    let onRetry: () -> Void

    var body: some View {
        switch message.role {
        case .reader:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("btr-chat-question")
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                switch message.state {
                case .pending(let status):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("btr-chat-pending")
                case .complete:
                    MarkdownText(message.text)
                        .accessibilityIdentifier("btr-chat-reply")
                case .failed(let error):
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("btr-chat-error")
                    Button("Try Again", action: onRetry)
                        .font(.footnote)
                        .accessibilityIdentifier("btr-chat-retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
