import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing

@testable import ReadBTR

@MainActor
struct BTRMenuViewModelTests {
    /// Canned-response `AIProvider` — records every prompt it was asked to
    /// answer, so tests can assert whether (and what) it was called with,
    /// without a real network call.
    final class MockAIProvider: AIProvider, @unchecked Sendable {
        var textToReturn = ""
        var errorToThrow: Error?
        private(set) var promptsReceived: [(prompt: String, schema: AIResponseSchema?)] = []

        func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String {
            promptsReceived.append((prompt, responseSchema))
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }
    }

    /// Real `Book`/`Publication` via the existing fixture pipeline, plus a
    /// real word-segment locator midway through the first real chapter —
    /// mirrors `BTRContextWindowTests`' setup, since the pipeline under
    /// test is built directly on top of that same context-resolution chain.
    /// A named struct rather than a tuple — five members is past the point
    /// a tuple stays readable at each call site.
    @MainActor
    struct Fixture {
        let book: Book
        let publication: Publication
        let anchorLocator: Locator
        let context: ModelContext
        let cleanup: () -> Void

        func makeViewModel(
            provider: AIProvider?, anchorLocator: Locator? = nil,
            enabledFeatures: Set<AIFeatureKey> = Set(BTRMenuViewModel.menuFeatures)
        ) -> BTRMenuViewModel {
            BTRMenuViewModel(
                book: book, publication: publication, anchorLocator: anchorLocator ?? self.anchorLocator,
                provider: provider, enabledFeatures: enabledFeatures, modelContext: context)
        }

        func makeFromSettings() -> BTRMenuViewModel? {
            BTRMenuViewModel.make(
                book: book, publication: publication, anchorLocator: anchorLocator, modelContext: context)
        }

        /// Sets the global AI settings the way the Configuration screen
        /// would: provider chosen, master toggle, and the per-feature flags.
        func configureAI(masterOn: Bool, enabled: Set<AIFeatureKey>) {
            let settings = AppSettingsStore.current(in: context)
            settings.aiProvider = .gemini
            settings.aiFeaturesMasterToggle = masterOn
            settings.aiFeatureFlags = AIFeatureKey.allCases.map {
                AIFeatureFlag(key: $0, isEnabled: enabled.contains($0))
            }
        }
    }

    private static func makeFixture() async throws -> Fixture {
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
        let anchorLocator = stream.words[50].locator

        return Fixture(
            book: book, publication: publication, anchorLocator: anchorLocator, context: context, cleanup: cleanup)
    }

    // MARK: - Preview pane

    @Test func preparePreviewBuildsANavigatorHostAtTheAnchorLocator() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        #expect(viewModel.previewNavigatorHost == nil)

        viewModel.preparePreview()
        #expect(viewModel.previewNavigatorHost != nil)
    }

    @Test func preparePreviewIsIdempotent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        viewModel.preparePreview()
        let first = viewModel.previewNavigatorHost
        viewModel.preparePreview()

        #expect(viewModel.previewNavigatorHost === first)
    }

    // MARK: - Step 1: entity extraction

    @Test func loadEntitiesPopulatesChipsFromProviderResponse() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"""
            {"entities":[{"name":"Alice","kind":"character"},{"name":"Wonderland","kind":"location"}]}
            """#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.loadEntities()

        guard case .result(let entities) = viewModel.entitiesState else {
            Issue.record("expected .result, got \(viewModel.entitiesState)")
            return
        }
        #expect(
            entities == [
                ExtractedEntity(name: "Alice", kind: .character),
                ExtractedEntity(name: "Wonderland", kind: .location),
            ])
        #expect(provider.promptsReceived.count == 1)
        if case .json = provider.promptsReceived.first?.schema {
            // expected — entity extraction requests structured output.
        } else {
            Issue.record("expected a .json response schema for entity extraction")
        }
    }

    @Test func loadEntitiesFailsGracefullyWithoutAProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let viewModel = fixture.makeViewModel(provider: nil)
        await viewModel.loadEntities()

        guard case .failed = viewModel.entitiesState else {
            Issue.record("expected .failed, got \(viewModel.entitiesState)")
            return
        }
    }

    @Test func loadEntitiesOnlyCallsTheProviderOnce() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"{"entities":[]}"#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.loadEntities()
        await viewModel.loadEntities()

        #expect(provider.promptsReceived.count == 1)
    }

    // MARK: - Step 2: entity summary

    @Test func selectEntityUsesCachedProfileWithoutCallingProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let existing = EntityProfile(
            displayName: "Alice", kind: .character, summary: "Cached summary.", firstMentionLocatorJSON: "",
            book: fixture.book)
        fixture.context.insert(existing)
        try fixture.context.save()

        let provider = MockAIProvider()
        provider.textToReturn = "Should never be returned."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "alice", kind: .character))

        #expect(viewModel.selectedOptionResult == .result("Cached summary."))
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func selectEntitySavesANewProfileWhenNotCached() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.book.entityProfiles.isEmpty)

        let provider = MockAIProvider()
        provider.textToReturn = "Alice is the curious protagonist."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "Alice", kind: .character))

        #expect(viewModel.selectedOptionResult == .result("Alice is the curious protagonist."))
        #expect(provider.promptsReceived.count == 1)
        #expect(fixture.book.entityProfiles.count == 1)
        #expect(fixture.book.entityProfiles.first?.canonicalName == "alice")
        #expect(fixture.book.entityProfiles.first?.summary == "Alice is the curious protagonist.")
    }

    @Test func selectEntityFailsWhenNoMentionsFound() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.selectEntity(ExtractedEntity(name: "Zzyzxqplorp", kind: .character))

        guard case .failed = viewModel.selectedOptionResult else {
            Issue.record("expected .failed, got \(viewModel.selectedOptionResult)")
            return
        }
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.entityProfiles.isEmpty)
    }

    // MARK: - "Summarize since start of chapter"

    @Test func summarizeChapterGeneratesAndCachesANewSummary() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.book.chapterSummaries.isEmpty)

        let provider = MockAIProvider()
        provider.textToReturn = "Alice fell down a rabbit hole."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Alice fell down a rabbit hole."))
        #expect(provider.promptsReceived.count == 1)
        #expect(fixture.book.chapterSummaries.count == 1)
        #expect(fixture.book.chapterSummaries.first?.chapterHref == fixture.anchorLocator.href.string)
    }

    @Test func summarizeChapterReusesAFreshCacheWithoutCallingProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        // Pin the anchor's own progression explicitly rather than trusting
        // whatever progression a real word-segment locator happens to
        // carry natively — `isStale` only ever compares these two
        // progression values against each other, so the test controls both
        // sides directly.
        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        // Covers *past* the anchor's own progression — not stale.
        let coveringLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 1.0) })
        let cached = ChapterSummary(
            chapterHref: fixture.anchorLocator.href.string, content: "Cached chapter summary.",
            sourceEndLocatorJSON: try coveringLocator.jsonString(), book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Cached chapter summary."))
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.chapterSummaries.count == 1)
    }

    @Test func summarizeChapterRegeneratesAndOverwritesAStaleCache() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        // Covers *before* the anchor's own progression — stale, since the
        // reader has read further into the chapter since it was made.
        let staleLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.0) })
        let cached = ChapterSummary(
            chapterHref: fixture.anchorLocator.href.string, content: "Old summary.",
            sourceEndLocatorJSON: try staleLocator.jsonString(), book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        provider.textToReturn = "Fresh summary."
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .result("Fresh summary."))
        #expect(provider.promptsReceived.count == 1)
        // Overwrote the existing row rather than creating a second one.
        #expect(fixture.book.chapterSummaries.count == 1)
        #expect(fixture.book.chapterSummaries.first?.content == "Fresh summary.")
    }

    // MARK: - AI feature toggles

    @Test func makeReturnsNilWhenMasterToggleIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        fixture.configureAI(masterOn: false, enabled: [.entityExtraction, .chapterSummary])

        #expect(fixture.makeFromSettings() == nil)
        #expect(BTRMenuViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
    }

    @Test func makeReturnsNilWithoutAnAPIKeyEvenWhenTogglesAreOn() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore()

        fixture.configureAI(masterOn: true, enabled: [.entityExtraction, .chapterSummary])

        #expect(fixture.makeFromSettings() == nil)
        #expect(BTRMenuViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
    }

    @Test func makeReturnsNilWhenEveryMenuFeatureIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        fixture.configureAI(masterOn: true, enabled: [])

        #expect(fixture.makeFromSettings() == nil)
        #expect(BTRMenuViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
    }

    @Test func makeOnlyEnablesTheFeaturesThatAreTurnedOn() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        fixture.configureAI(masterOn: true, enabled: [.chapterSummary])

        let viewModel = try #require(fixture.makeFromSettings())
        #expect(viewModel.isChapterSummaryEnabled == true)
        #expect(viewModel.isEntityLookupEnabled == false)
        #expect(BTRMenuViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == true)
    }

    @Test func perBookOverrideCanTurnTheMenuOffForOneBook() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }
        let previous = AppSettings.keyStore
        defer { AppSettings.keyStore = previous }
        AppSettings.keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])

        fixture.configureAI(masterOn: true, enabled: [.entityExtraction, .chapterSummary])
        fixture.book.settingsOverride = BookSettingsOverride(aiFeatureFlagOverrides: [
            AIFeatureFlag(key: .entityExtraction, isEnabled: false),
            AIFeatureFlag(key: .chapterSummary, isEnabled: false),
        ])

        #expect(fixture.makeFromSettings() == nil)
        #expect(BTRMenuViewModel.isAvailable(for: fixture.book, modelContext: fixture.context) == false)
    }

    @Test func loadEntitiesDoesNothingWhenEntityLookupIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"{"entities":[{"name":"Alice","kind":"character"}]}"#
        let viewModel = fixture.makeViewModel(provider: provider, enabledFeatures: [.chapterSummary])

        await viewModel.loadEntities()

        #expect(viewModel.entitiesState == .idle)
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func selectEntityDoesNothingWhenEntityLookupIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = "Alice is the protagonist."
        let viewModel = fixture.makeViewModel(provider: provider, enabledFeatures: [.chapterSummary])

        await viewModel.selectEntity(ExtractedEntity(name: "Alice", kind: .character))

        #expect(viewModel.selectedOptionResult == .idle)
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.entityProfiles.isEmpty)
    }

    @Test func summarizeChapterDoesNothingWhenChapterSummaryIsOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = "Should never be returned."
        let viewModel = fixture.makeViewModel(provider: provider, enabledFeatures: [.entityExtraction])

        await viewModel.summarizeChapter()

        #expect(viewModel.selectedOptionResult == .idle)
        #expect(provider.promptsReceived.isEmpty)
        #expect(fixture.book.chapterSummaries.isEmpty)
    }

    // MARK: - Comprehension check

    private static let threeQuestionsJSON = #"""
        {"questions":[
          {"question":"Why does Alice follow the Rabbit?","choices":["Curiosity","Fear","Hunger","Duty"],"correctChoiceIndex":0,"explanation":"She is burning with curiosity."},
          {"question":"Where does the Rabbit go?","choices":["A tree","A rabbit-hole","A river","A house"],"correctChoiceIndex":1,"explanation":"It pops down a large rabbit-hole."},
          {"question":"How does Alice feel about falling?","choices":["Calm","Panicked","Angry","Sleepy"],"correctChoiceIndex":0,"explanation":"She wonders idly as she falls."}
        ]}
        """#

    @Test func startComprehensionCheckGeneratesAndSavesACheck() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = Self.threeQuestionsJSON
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.startComprehensionCheck()

        #expect(viewModel.activePanel == .comprehensionCheck)
        guard case .result(let check) = viewModel.comprehensionState else {
            Issue.record("expected .result, got \(viewModel.comprehensionState)")
            return
        }
        #expect(check.questions.count == 3)
        #expect(check.questions.allSatisfy { $0.selectedChoiceIndex == nil })
        #expect(check.chapterHref == fixture.anchorLocator.href.string)
        #expect(fixture.book.comprehensionChecks.count == 1)
        #expect(provider.promptsReceived.count == 1)
        if case .json = provider.promptsReceived.first?.schema {
            // expected — questions come back as structured output.
        } else {
            Issue.record("expected a .json response schema for comprehension checks")
        }
    }

    @Test func startComprehensionCheckDropsMalformedQuestions() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"""
            {"questions":[
              {"question":"Good?","choices":["A","B","C","D"],"correctChoiceIndex":2,"explanation":"C."},
              {"question":"Bad index?","choices":["A","B"],"correctChoiceIndex":5,"explanation":"?"},
              {"question":"One choice?","choices":["A"],"correctChoiceIndex":0,"explanation":"?"}
            ]}
            """#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.startComprehensionCheck()

        guard case .result(let check) = viewModel.comprehensionState else {
            Issue.record("expected .result, got \(viewModel.comprehensionState)")
            return
        }
        #expect(check.questions.map(\.question) == ["Good?"])
    }

    @Test func startComprehensionCheckFailsWhenNoUsableQuestions() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = #"{"questions":[]}"#
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.startComprehensionCheck()

        guard case .failed = viewModel.comprehensionState else {
            Issue.record("expected .failed, got \(viewModel.comprehensionState)")
            return
        }
        #expect(fixture.book.comprehensionChecks.isEmpty)
    }

    @Test func startComprehensionCheckReusesAFreshCheckWithoutCallingProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        let coveringLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 1.0) })
        let cached = ComprehensionCheck(
            chapterHref: fixture.anchorLocator.href.string, sourceEndLocatorJSON: try coveringLocator.jsonString(),
            questions: [
                ComprehensionQuestion(
                    question: "Cached?", choices: ["Yes", "No"], correctChoiceIndex: 0, explanation: "Yes.")
            ],
            book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.startComprehensionCheck()

        #expect(viewModel.comprehensionState == .result(cached))
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func startComprehensionCheckForceNewIgnoresTheCache() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let anchorAtHalf = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 0.5) })
        let coveringLocator = fixture.anchorLocator.copy(locations: { $0 = Locator.Locations(progression: 1.0) })
        let cached = ComprehensionCheck(
            chapterHref: fixture.anchorLocator.href.string, sourceEndLocatorJSON: try coveringLocator.jsonString(),
            questions: [
                ComprehensionQuestion(
                    question: "Cached?", choices: ["Yes", "No"], correctChoiceIndex: 0, explanation: "Yes.")
            ],
            book: fixture.book)
        fixture.context.insert(cached)
        try fixture.context.save()

        let provider = MockAIProvider()
        provider.textToReturn = Self.threeQuestionsJSON
        let viewModel = fixture.makeViewModel(provider: provider, anchorLocator: anchorAtHalf)

        await viewModel.startComprehensionCheck(forceNew: true)

        #expect(provider.promptsReceived.count == 1)
        #expect(fixture.book.comprehensionChecks.count == 2)
        guard case .result(let check) = viewModel.comprehensionState else {
            Issue.record("expected .result, got \(viewModel.comprehensionState)")
            return
        }
        #expect(check !== cached)
    }

    @Test func answeringEveryQuestionCompletesTheCheck() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = Self.threeQuestionsJSON
        let viewModel = fixture.makeViewModel(provider: provider)
        await viewModel.startComprehensionCheck()
        guard case .result(let check) = viewModel.comprehensionState else {
            Issue.record("expected .result, got \(viewModel.comprehensionState)")
            return
        }

        viewModel.answerComprehensionQuestion(at: 0, choiceIndex: 0)  // right
        viewModel.answerComprehensionQuestion(at: 0, choiceIndex: 3)  // ignored: already answered
        viewModel.answerComprehensionQuestion(at: 1, choiceIndex: 0)  // wrong
        #expect(check.completedAt == nil)
        viewModel.answerComprehensionQuestion(at: 2, choiceIndex: 0)  // right

        #expect(check.questions.map(\.selectedChoiceIndex) == [0, 0, 0])
        #expect(check.isComplete)
        #expect(check.correctCount == 2)
        #expect(check.completedAt != nil)
    }

    @Test func comprehensionCheckDoesNothingWhenTurnedOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = Self.threeQuestionsJSON
        let viewModel = fixture.makeViewModel(provider: provider, enabledFeatures: [.questionAnswering])

        await viewModel.startComprehensionCheck()

        #expect(viewModel.activePanel == .none)
        #expect(viewModel.comprehensionState == .idle)
        #expect(provider.promptsReceived.isEmpty)
    }

    // MARK: - Q&A

    @Test func askQuestionAnswersFromTextReadSoFar() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = "  She was bored and saw a White Rabbit.  "
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.askQuestion("  Why did Alice leave the riverbank?  ")

        #expect(viewModel.activePanel == .questionAnswering)
        #expect(viewModel.qaExchanges.count == 1)
        #expect(viewModel.qaExchanges.first?.question == "Why did Alice leave the riverbank?")
        #expect(viewModel.qaExchanges.first?.answer == .result("She was bored and saw a White Rabbit."))
        #expect(viewModel.isAnsweringQuestion == false)

        let sent = try #require(provider.promptsReceived.first)
        #expect(sent.prompt.contains("Why did Alice leave the riverbank?"))
        #expect(sent.prompt.contains(fixture.book.title))
        if case .plainText = sent.schema {
            // expected
        } else {
            Issue.record("expected a .plainText response schema for Q&A")
        }
    }

    @Test func followUpQuestionsIncludeEarlierExchanges() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.textToReturn = "Because of the White Rabbit."
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.askQuestion("Why did she run?")
        provider.textToReturn = "Down the rabbit-hole."
        await viewModel.askQuestion("Where did she go?")

        #expect(viewModel.qaExchanges.count == 2)
        #expect(provider.promptsReceived.count == 2)
        let second = provider.promptsReceived[1].prompt
        #expect(second.contains("Why did she run?"))
        #expect(second.contains("Because of the White Rabbit."))
        #expect(second.contains("Where did she go?"))
    }

    @Test func askQuestionIgnoresBlankInput() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.askQuestion("   \n ")

        #expect(viewModel.qaExchanges.isEmpty)
        #expect(provider.promptsReceived.isEmpty)
    }

    @Test func askQuestionShowsProviderErrors() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        provider.errorToThrow = AIProviderError.emptyResponse
        let viewModel = fixture.makeViewModel(provider: provider)

        await viewModel.askQuestion("Who is the Rabbit?")

        guard case .failed = viewModel.qaExchanges.first?.answer else {
            Issue.record("expected .failed, got \(String(describing: viewModel.qaExchanges.first?.answer))")
            return
        }
    }

    @Test func askQuestionDoesNothingWhenTurnedOff() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let provider = MockAIProvider()
        let viewModel = fixture.makeViewModel(provider: provider, enabledFeatures: [.comprehensionCheck])

        viewModel.openQuestionAnswering()
        await viewModel.askQuestion("Who is the Rabbit?")

        #expect(viewModel.activePanel == .none)
        #expect(viewModel.qaExchanges.isEmpty)
        #expect(provider.promptsReceived.isEmpty)
    }

    // MARK: - Read-so-far text (Q&A spoiler avoidance)

    @Test func readSoFarTextStopsAtTheReadersPosition() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanup() }

        let readingOrder = fixture.publication.readingOrder
        try #require(readingOrder.count > 2)

        let result = try #require(
            await BTRReadSoFarTextExtractor.extractText(upTo: fixture.anchorLocator, in: fixture.publication))
        #expect(result.wasTruncated == false)

        // Includes what's already been read in this chapter…
        let chapterSoFar = try #require(
            await BTRChapterTextExtractor.extractText(upTo: fixture.anchorLocator, in: fixture.publication))
        #expect(result.text.hasSuffix(chapterSoFar))

        // …but nothing from the next chapter.
        let nextChapterPieces = await BTRChapterTextExtractor.textPieces(
            ofResource: readingOrder[2].url().string, upToProgression: nil, in: fixture.publication)
        let laterPiece = try #require(nextChapterPieces.first { $0.count > 40 })
        #expect(!result.text.contains(laterPiece))
    }

    @Test func truncatingFromStartKeepsTheMostRecentText() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let result = BTRReadSoFarTextExtractor.truncatingFromStart(text, maxCharacters: 30)
        #expect(result.wasTruncated)
        #expect(result.text == "Third paragraph.")

        let untouched = BTRReadSoFarTextExtractor.truncatingFromStart(text, maxCharacters: 1000)
        #expect(untouched == .init(text: text, wasTruncated: false))
    }
}
