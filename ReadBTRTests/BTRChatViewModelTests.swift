import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
@Suite(.serialized)
struct BTRChatViewModelTests {
    /// Canned-response `AIProvider` — records every call, so tests can
    /// assert whether (and with what) it was called, without a network.
    final class MockAIProvider: AIProvider, @unchecked Sendable {
        var textToReturn = "A reply."
        var errorToThrow: Error?
        private(set) var promptsReceived: [(prompt: String, schema: AIResponseSchema?)] = []
        private(set) var chatsReceived: [(systemPrompt: String, messages: [AIChatMessage])] = []

        func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String {
            promptsReceived.append((prompt, responseSchema))
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }

        func generateChatReply(systemPrompt: String, messages: [AIChatMessage]) async throws -> String {
            chatsReceived.append((systemPrompt, messages))
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }
    }

    /// A real imported `Book`/`Publication` and a real word locator midway
    /// through the first real chapter.
    @MainActor
    struct Fixture {
        let book: Book
        let publication: Publication
        let anchorLocator: Locator
        let context: ModelContext
        let storage: BookFileStorage
        let cleanup: () -> Void

        func makeViewModel(provider: AIProvider?, earlierBooks: [Book]? = nil) -> BTRChatViewModel {
            BTRChatViewModel(
                book: book, publication: publication, anchorLocator: anchorLocator, provider: provider,
                modelContext: context, earlierBooks: earlierBooks, fileStorage: storage)
        }

        func importAnotherCopy() async throws -> Book {
            let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
            let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
            try context.save()
            return book
        }

        func configureAI(masterOn: Bool, chatOn: Bool) {
            let settings = AppSettingsStore.current(in: context)
            settings.aiProvider = .gemini
            settings.aiFeaturesMasterToggle = masterOn
            settings.aiFeatureFlags = [AIFeatureFlag(key: .btrChat, isEnabled: chatOn)]
        }
    }

    static func makeFixture() async throws -> Fixture {
        let (storage, cleanup) = try RSVPViewModelTests.makeTempStorage()
        let context = try RSVPViewModelTests.makeContext()
        let importer = BookImporter(fileStorage: storage, publicationLoader: PublicationLoader())
        let book = try await importer.importBook(from: RSVPViewModelTests.fixtureURL, into: context)
        try context.save()

        let fileURL = try storage.absoluteURL(forRelativePath: book.relativeFilePath)
        let publication = try await PublicationLoader().open(fileURL: fileURL)

        let chapterHref = publication.readingOrder[1].url().string
        let stream = try #require(await WordStream.build(for: chapterHref, in: publication))
        try #require(stream.words.count > 50)

        return Fixture(
            book: book, publication: publication, anchorLocator: stream.words[50].locator, context: context,
            storage: storage, cleanup: cleanup)
    }

    private func withKey<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])
        return try await body()
    }

    // MARK: - Gating

    @Test func hiddenWhenTheChatIsOffOrAIIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        try await withKey {
            fixture.configureAI(masterOn: true, chatOn: false)
            #expect(BTRChatViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
            #expect(
                BTRChatViewModel.make(
                    book: fixture.book, publication: fixture.publication, anchorLocator: fixture.anchorLocator,
                    modelContext: fixture.context) == nil)

            fixture.configureAI(masterOn: false, chatOn: true)
            #expect(BTRChatViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)

            fixture.configureAI(masterOn: true, chatOn: true)
            #expect(BTRChatViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == true)
            #expect(
                BTRChatViewModel.make(
                    book: fixture.book, publication: fixture.publication, anchorLocator: fixture.anchorLocator,
                    modelContext: fixture.context) != nil)
        }
    }

    @Test func hiddenWithoutAnAPIKey() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore()
        fixture.configureAI(masterOn: true, chatOn: true)

        #expect(BTRChatViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
    }

    // MARK: - The passage

    @Test func contextWordsSurroundTheAnchorAndStartSelected() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        await viewModel.loadContextWords()

        #expect(viewModel.contextWords.count == 21)
        let anchors = viewModel.contextWords.filter(\.isAnchor)
        #expect(anchors.count == 1)
        #expect(anchors.first?.id == 10)
        #expect(viewModel.selectedWordIDs == [10])

        viewModel.toggleWord(viewModel.contextWords[11])
        #expect(viewModel.selectedWordIDs == [10, 11])
        viewModel.toggleWord(viewModel.contextWords[10])
        #expect(viewModel.selectedWordIDs == [11])
    }

    // MARK: - Asking

    @Test func askSendsMarkdownSystemPromptExcerptsAndQuestion() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = "**Alice** is bored."
        let viewModel = fixture.makeViewModel(provider: provider)
        await viewModel.loadContextWords()

        await viewModel.ask("Why is Alice bored?")

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].role == .reader)
        #expect(viewModel.messages[1].text == "**Alice** is bored.")
        #expect(viewModel.messages[1].state == .complete)

        let chat = try #require(provider.chatsReceived.first)
        #expect(chat.systemPrompt.contains("Markdown"))
        let turn = try #require(chat.messages.last?.text)
        #expect(chat.messages.count == 1)
        #expect(turn.contains("Reader's question: Why is Alice bored?"))
        #expect(turn.contains("The reader opened this chat from this passage"))
        #expect(turn.contains("current book, from the start up to the reader's position"))
        // A short book fits whole, so no search-planning call was made.
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func excerptsNeverIncludeTextPastTheReadersPosition() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let laterHref = fixture.publication.readingOrder[3].url().string
        let laterText = await BTRChapterTextExtractor.textPieces(
            ofResource: laterHref, upToProgression: nil, in: fixture.publication)
        let laterParagraph = try #require(laterText.first { $0.count > 80 })

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider)
        await viewModel.ask("What happens next?")

        let turn = try #require(provider.chatsReceived.first?.messages.last?.text)
        #expect(!turn.contains(laterParagraph))
    }

    @Test func followUpQuestionsCarryTheConversation() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider)
        await viewModel.ask("Who is the White Rabbit?")
        provider.textToReturn = "Second reply."
        await viewModel.ask("Where is he going?")

        let second = try #require(provider.chatsReceived.last)
        #expect(second.messages.count == 3)
        #expect(second.messages[0] == AIChatMessage(role: .user, text: "Who is the White Rabbit?"))
        #expect(second.messages[1] == AIChatMessage(role: .assistant, text: "A reply."))
        #expect(second.messages[2].text.contains("Where is he going?"))
        #expect(viewModel.messages.count == 4)
    }

    @Test func withoutAProviderTheReplyExplainsHowToSetUpAI() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        await viewModel.ask("Anything?")

        #expect(viewModel.messages.last?.state == .failed(BTRChatViewModel.noProviderMessage))
    }

    @Test func aFailedReplyCanBeRetried() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.errorToThrow = AIProviderError.emptyResponse
        let viewModel = fixture.makeViewModel(provider: provider)
        await viewModel.ask("Who is Dinah?")

        let failed = try #require(viewModel.messages.last)
        guard case .failed = failed.state else {
            Issue.record("expected a failed reply, got \(failed.state)")
            return
        }

        provider.errorToThrow = nil
        provider.textToReturn = "Alice's cat."
        await viewModel.retry(failed)

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.last?.text == "Alice's cat.")
        #expect(viewModel.messages.last?.state == .complete)
        #expect(provider.chatsReceived.last?.messages.last?.text.contains("Who is Dinah?") == true)
    }

    @Test func blankQuestionsAreIgnored() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: MockAIProvider())
        viewModel.draft = "   "
        #expect(viewModel.canSend == false)
        await viewModel.sendDraft()
        #expect(viewModel.messages.isEmpty)
    }

    // MARK: - Collections

    @Test func earlierBooksInTheCollectionAreReadInFull() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let earlier = try await fixture.importAnotherCopy()
        let collection = BookCollection(name: "Series")
        fixture.context.insert(collection)
        collection.append(earlier, in: fixture.context)
        collection.append(fixture.book, in: fixture.context)
        // A later book must never be used.
        let later = try await fixture.importAnotherCopy()
        collection.append(later, in: fixture.context)

        let provider = MockAIProvider()
        let viewModel = BTRChatViewModel(
            book: fixture.book, publication: fixture.publication, anchorLocator: fixture.anchorLocator,
            provider: provider, modelContext: fixture.context, fileStorage: fixture.storage)
        #expect(viewModel.earlierBookTitles.count == 1)

        await viewModel.ask("What happened in the first book?")

        let chat = try #require(provider.chatsReceived.first)
        #expect(chat.systemPrompt.contains("Before it they read"))
        let turn = try #require(chat.messages.last?.text)
        #expect(turn.components(separatedBy: "(an earlier book the reader has finished)").count == 2)

        // The earlier book is read to its end: its last chapter is there.
        let lastHref = try #require(fixture.publication.readingOrder.last?.url().string)
        let lastChapter = await BTRChapterTextExtractor.textPieces(
            ofResource: lastHref, upToProgression: nil, in: fixture.publication)
        if let ending = lastChapter.last(where: { $0.count > 40 }) {
            #expect(turn.contains(ending))
        }
    }

    // MARK: - Page chats

    @Test func pageLocatorMovesToThePageEndAndDropsText() throws {
        let fixture = try BTRChatPageFixture.locator(progression: 0.4)
        let end = VisiblePageLocator.pageLocator(from: fixture, endProgression: 0.55)
        #expect(end.locations.progression == 0.55)
        #expect(end.text.highlight == nil)
        #expect(end.href == fixture.href)
        // Never moves backward, and never past the resource's end.
        #expect(VisiblePageLocator.pageLocator(from: fixture, endProgression: 0.1).locations.progression == 0.4)
        #expect(VisiblePageLocator.pageLocator(from: fixture, endProgression: 3).locations.progression == 1)
        #expect(VisiblePageLocator.pageLocator(from: fixture, endProgression: nil).locations.progression == 0.4)
    }

    @Test func aPageChatHasNoPassageAndTellsTheModelItCameFromThePage() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let anchor = VisiblePageLocator.pageLocator(from: fixture.anchorLocator, endProgression: nil)
        let viewModel = BTRChatViewModel(
            book: fixture.book, publication: fixture.publication, anchorLocator: anchor, kind: .page,
            chapterTitle: "Down the Rabbit-Hole", provider: provider, modelContext: fixture.context,
            earlierBooks: [], fileStorage: fixture.storage)
        await viewModel.loadContextWords()
        #expect(viewModel.contextWords.isEmpty)
        #expect(viewModel.focus == nil)

        await viewModel.ask("What's happening on this page?")
        let turn = try #require(provider.chatsReceived.first?.messages.last?.text)
        #expect(turn.contains("opened this chat from the page they are on"))
        #expect(!turn.contains("from this passage"))
        #expect(turn.contains("current book, from the start up to the reader's position"))
    }

    // MARK: - Saving

    @Test func aChatIsSavedOnceAQuestionIsAsked() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: MockAIProvider())
        await viewModel.loadContextWords()
        #expect(fixture.book.btrChats.isEmpty)

        await viewModel.ask("Who is Alice?")
        let saved = try #require(viewModel.savedChat)
        #expect(fixture.book.btrChats.count == 1)
        #expect(saved.kind == .selection)
        #expect(saved.title == "Who is Alice?")
        #expect(saved.messages.map(\.text) == ["Who is Alice?", "A reply."])
        #expect(saved.selectedWordIDs == [10])
        let storedAnchor = try Locator(jsonString: saved.anchorLocatorJSON)
        #expect(storedAnchor.href == fixture.anchorLocator.href)
        #expect(storedAnchor.locations.progression == fixture.anchorLocator.locations.progression)

        await viewModel.ask("And the Rabbit?")
        #expect(fixture.book.btrChats.count == 1)
        #expect(saved.questionCount == 2)
        #expect(viewModel.savedChats.first?.id == saved.id)
    }

    @Test func failedRepliesAreLeftOutOfTheSavedChat() {
        let messages = [
            BTRChatMessage(role: .reader, text: "One"),
            BTRChatMessage(role: .assistant, text: "Reply"),
            BTRChatMessage(role: .reader, text: "Two"),
            BTRChatMessage(role: .assistant, text: "", state: .failed("Nope")),
            BTRChatMessage(role: .reader, text: "Three"),
            BTRChatMessage(role: .assistant, text: "", state: .pending("Thinking…")),
        ]
        let stored = BTRChatViewModel.storedMessages(from: messages)
        #expect(stored.map(\.text) == ["One", "Reply", "Two", "Three"])
    }

    @Test func aSavedChatReopensWithItsConversationAndCanContinue() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let first = fixture.makeViewModel(provider: provider)
        await first.loadContextWords()
        first.toggleWord(first.contextWords[12])
        await first.ask("Who is Alice?")
        let saved = try #require(first.savedChat)

        // A fresh page chat elsewhere, then reopen the first one in it.
        let pageAnchor = VisiblePageLocator.pageLocator(from: fixture.anchorLocator, endProgression: 1)
        let second = BTRChatViewModel(
            book: fixture.book, publication: fixture.publication, anchorLocator: pageAnchor, kind: .page,
            provider: provider, modelContext: fixture.context, earlierBooks: [], fileStorage: fixture.storage)
        second.reopen(saved)
        await second.loadContextWords()

        #expect(second.kind == .selection)
        #expect(second.anchorLocator.href == fixture.anchorLocator.href)
        #expect(second.anchorLocator.locations.progression == fixture.anchorLocator.locations.progression)
        #expect(second.messages.map(\.text) == ["Who is Alice?", "A reply."])
        #expect(second.selectedWordIDs == [10, 12])
        #expect(second.contextWords.count == 21)

        provider.textToReturn = "Follow-up."
        await second.ask("What is she doing?")
        let followUp = try #require(provider.chatsReceived.last)
        #expect(followUp.messages.first == AIChatMessage(role: .user, text: "Who is Alice?"))
        #expect(fixture.book.btrChats.count == 1)
        #expect(saved.questionCount == 2)

        second.delete(saved)
        #expect(fixture.book.btrChats.isEmpty)
        #expect(second.savedChat == nil)
    }
}

/// A bare locator for the pure page-locator helper.
enum BTRChatPageFixture {
    static func locator(progression: Double) throws -> Locator {
        try Locator(
            jsonString: #"{"href":"chapter1.xhtml","type":"application/xhtml+xml","locations":{"progression":\#(progression)},"text":{"highlight":"word"}}"#
        )
    }
}
