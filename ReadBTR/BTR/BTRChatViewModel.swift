import Foundation
import Observation
@preconcurrency import ReadiumShared
import SwiftData

/// One message in the BTR chat.
struct BTRChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case reader
        case assistant
    }

    enum State: Equatable {
        case complete
        /// Waiting on the reply; the text is the progress line to show.
        case pending(String)
        case failed(String)
    }

    let id: UUID
    var role: Role
    var text: String
    var state: State

    init(id: UUID = UUID(), role: Role, text: String, state: State = .complete) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
    }
}

/// Drives the BTR chat (design-roadmap.md §6.6): the passage the chat was
/// opened from (with selectable words), and a spoiler-free conversation
/// about the book — and, through `BTRChatContextAgent`, the books before it
/// in any of its collections.
///
/// `anchorLocator` is the reading position the chat was opened *at*: RSVP's
/// current word, or Guided/Normal Reading's text selection. It never moves
/// while the chat is open, so the readable text doesn't either.
@MainActor
@Observable
final class BTRChatViewModel {
    let book: Book
    let publication: Publication
    let anchorLocator: Locator
    let theme: ReaderTheme

    /// The passage at the top of the chat: the anchor word(s) plus up to
    /// 10 words either side.
    private(set) var contextWords: [BTRContextWord] = []
    /// The words the reader has selected in the passage (by
    /// `BTRContextWord.id`). Starts as the anchor word(s).
    var selectedWordIDs: Set<Int> = []

    private(set) var messages: [BTRChatMessage] = []
    var draft = ""

    /// Titles of the earlier books in this book's collections that the
    /// chat may draw on, in reading order.
    let earlierBookTitles: [String]

    var isResponding: Bool {
        messages.contains { if case .pending = $0.state { true } else { false } }
    }

    var canSend: Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var focus: PromptBuilder.ChatFocus? {
        BTRContextWords.focus(for: contextWords, selected: selectedWordIDs)
    }

    private let provider: AIProvider?
    private let agent: BTRChatContextAgent
    private let wordStreamCache: WordStreamCache

    /// How many earlier messages go along with each new question.
    static let maxHistoryMessages = 10

    init(
        book: Book,
        publication: Publication,
        anchorLocator: Locator,
        provider: AIProvider?,
        modelContext: ModelContext,
        earlierBooks: [Book]? = nil,
        fileStorage: BookFileStorage = BookFileStorage(),
        wordStreamCache: WordStreamCache = WordStreamCache()
    ) {
        self.book = book
        self.publication = publication
        self.anchorLocator = anchorLocator
        self.provider = provider
        self.wordStreamCache = wordStreamCache
        theme = book.effectiveTheme(AppSettingsStore.current(in: modelContext))

        let earlier = earlierBooks ?? book.earlierBooksInCollections
        earlierBookTitles = earlier.map(\.title)
        agent = BTRChatContextAgent(
            sources: Self.sources(
                earlierBooks: earlier, currentBook: book, publication: publication, anchorLocator: anchorLocator,
                fileStorage: fileStorage))
    }

    /// The one place every reading mode builds the chat from. Returns `nil`
    /// when the BTR chat isn't enabled for `book` (master AI toggle,
    /// provider + key, the feature flag and any per-book override), so the
    /// reading modes can hide their BTR entry point instead.
    static func make(
        book: Book, publication: Publication, anchorLocator: Locator, modelContext: ModelContext
    ) -> BTRChatViewModel? {
        let appSettings = AppSettingsStore.current(in: modelContext)
        guard book.isAIFeatureEnabled(.btrChat, appSettings) else { return nil }
        let provider = AIProviderFactory.makeProvider(settings: appSettings, keyStore: AppSettings.keyStore)
        return BTRChatViewModel(
            book: book, publication: publication, anchorLocator: anchorLocator, provider: provider,
            modelContext: modelContext)
    }

    /// Whether the BTR entry point should be shown at all for `book`.
    static func isAvailable(for book: Book, modelContext: ModelContext) -> Bool {
        book.isAIFeatureEnabled(.btrChat, AppSettingsStore.current(in: modelContext))
    }

    private static func sources(
        earlierBooks: [Book], currentBook: Book, publication: Publication, anchorLocator: Locator,
        fileStorage: BookFileStorage
    ) -> [BTRChatContextAgent.Source] {
        var sources = earlierBooks.map { earlier in
            let bookID = earlier.id
            let relativePath = earlier.relativeFilePath
            return BTRChatContextAgent.Source(
                bookID: bookID, title: earlier.title, isCurrentBook: false,
                load: {
                    if let cached = BTRBookTextCache.shared.fullText(for: bookID) { return cached }
                    guard let url = try? fileStorage.absoluteURL(forRelativePath: relativePath),
                        let earlierPublication = try? await PublicationLoader().open(fileURL: url)
                    else { return nil }
                    let passages = await BTRBookTextExtractor.passages(of: earlierPublication, upTo: nil)
                    if !passages.isEmpty { BTRBookTextCache.shared.store(passages, for: bookID) }
                    return passages
                })
        }
        sources.append(
            BTRChatContextAgent.Source(
                bookID: currentBook.id, title: currentBook.title, isCurrentBook: true,
                load: { await BTRBookTextExtractor.passages(of: publication, upTo: anchorLocator) }))
        return sources
    }

    // MARK: - The passage at the top

    /// Builds the passage around the anchor. Safe to call repeatedly.
    func loadContextWords() async {
        guard contextWords.isEmpty,
            let stream = await wordStreamCache.stream(for: anchorLocator.href.string, in: publication)
        else { return }
        contextWords = BTRContextWords.build(around: anchorLocator, in: stream)
        selectedWordIDs = Set(contextWords.filter(\.isAnchor).map(\.id))
    }

    func toggleWord(_ word: BTRContextWord) {
        if selectedWordIDs.contains(word.id) {
            selectedWordIDs.remove(word.id)
        } else {
            selectedWordIDs.insert(word.id)
        }
    }

    // MARK: - Asking

    func sendDraft() async {
        guard canSend else { return }
        let question = draft
        draft = ""
        await ask(question)
    }

    func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        let history = Self.conversationHistory(from: messages)
        messages.append(BTRChatMessage(role: .reader, text: question))
        let reply = BTRChatMessage(role: .assistant, text: "", state: .pending("Thinking…"))
        messages.append(reply)
        await answer(question, history: history, replyID: reply.id)
    }

    /// Re-asks the question before a failed reply.
    func retry(_ message: BTRChatMessage) async {
        guard case .failed = message.state, !isResponding,
            let index = messages.firstIndex(where: { $0.id == message.id }), index > 0,
            messages[index - 1].role == .reader
        else { return }
        let question = messages[index - 1].text
        let history = Self.conversationHistory(from: Array(messages[..<(index - 1)]))
        messages[index].state = .pending("Thinking…")
        messages[index].text = ""
        await answer(question, history: history, replyID: message.id)
    }

    private func answer(_ question: String, history: [AIChatMessage], replyID: UUID) async {
        guard let provider else {
            update(replyID, state: .failed(Self.noProviderMessage))
            return
        }

        let focus = self.focus
        let context = await agent.gatherContext(
            question: question, focus: focus, recentConversation: Array(history.suffix(4)), provider: provider,
            onStatus: { [weak self] status in self?.update(replyID, state: .pending(status)) })

        guard !context.excerpts.isEmpty else {
            update(replyID, state: .failed("Couldn't find any text up to this point."))
            return
        }

        update(replyID, state: .pending("Thinking…"))
        let systemPrompt = PromptBuilder.chatSystemPrompt(
            currentBookTitle: book.title,
            earlierBookTitles: earlierBookTitles.filter { !context.unavailableTitles.contains($0) })
        let turn = PromptBuilder.chatTurn(question: question, focus: focus, excerpts: context.excerpts)

        do {
            let text = try await provider.generateChatReply(
                systemPrompt: systemPrompt, messages: history + [AIChatMessage(role: .user, text: turn)])
            guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
            messages[index].text = Self.cleanReply(text)
            messages[index].state = .complete
        } catch {
            update(replyID, state: .failed(error.localizedDescription))
        }
    }

    private func update(_ id: UUID, state: BTRChatMessage.State) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
    }

    /// Earlier completed exchanges, as plain question/answer turns.
    static func conversationHistory(from messages: [BTRChatMessage]) -> [AIChatMessage] {
        var history: [AIChatMessage] = []
        var index = 0
        while index + 1 < messages.count {
            let question = messages[index]
            let reply = messages[index + 1]
            if question.role == .reader, reply.role == .assistant, reply.state == .complete {
                history.append(AIChatMessage(role: .user, text: question.text))
                history.append(AIChatMessage(role: .assistant, text: reply.text))
                index += 2
            } else {
                index += 1
            }
        }
        return Array(history.suffix(maxHistoryMessages))
    }

    /// Models sometimes wrap a whole Markdown reply in a ```markdown fence
    /// despite being told not to; unwrap it so it renders.
    nonisolated static func cleanReply(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for opener in ["```markdown\n", "```md\n", "```\n"] where trimmed.hasPrefix(opener) && trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropFirst(opener.count).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return trimmed
    }

    static let noProviderMessage = "AI features aren't set up — add a provider and API key in Settings."
}
