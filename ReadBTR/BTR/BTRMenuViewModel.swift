import Foundation
import Observation
@preconcurrency import ReadiumShared
import SwiftData

/// One entity extracted from the ±100-word window around the reader's
/// position (design-roadmap.md §6.6.3 step 1) — decoded directly from
/// Gemini's structured JSON output (`PromptBuilder.entityExtractionSchema`),
/// not yet backed by a saved `EntityProfile` until the reader actually taps
/// it.
struct ExtractedEntity: Decodable, Identifiable, Equatable {
    var name: String
    var kind: EntityKind

    var id: String { name }
}

/// The top-level shape Gemini's structured entity-extraction response
/// decodes into — mirrors `PromptBuilder.entityExtractionSchema` exactly.
private struct EntityExtractionResponse: Decodable {
    var entities: [ExtractedEntity]
}

/// Mirrors `PromptBuilder.comprehensionCheckSchema`.
private struct ComprehensionCheckResponse: Decodable {
    var questions: [ComprehensionQuestion]
}

/// Which of the BTR options currently owns the bottom result area — only
/// one is shown at a time.
enum BTRActivePanel: Equatable {
    case none
    /// An entity summary or the chapter summary (`selectedOptionResult`).
    case textResult
    case comprehensionCheck
    case questionAnswering
}

/// One question the reader asked in the Q&A panel and its answer.
/// Session-only: Q&A isn't persisted, unlike comprehension checks.
struct BTRQAExchange: Identifiable, Equatable {
    let id: UUID
    var question: String
    var answer: BTRResultState<String>

    init(id: UUID = UUID(), question: String, answer: BTRResultState<String> = .loading) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

/// Shared "pending → result" shape for both BTR options (design-roadmap.md
/// §6.6.3/§6.6.4: "one shared component, not two bespoke implementations")
/// and for the automatic entity-extraction step itself.
enum BTRResultState<T: Equatable>: Equatable {
    case idle
    case loading
    case result(T)
    case failed(String)
}

/// Drives the BTR menu screen (design-roadmap.md §6.6.2-§6.6.4): fires
/// entity extraction automatically on open, then resolves either option —
/// a tapped entity chip, or "summarize since start of chapter" — through
/// the deterministic two-step pipelines the design calls for (a fixed
/// pipeline, not a tool-calling agent loop, per §9's decision log).
///
/// `anchorLocator` is the reading position the menu was opened *at* —
/// deliberately the same across all three activation mechanisms (RSVP's
/// current word, Guided Reading's/Normal's text selection); the exact
/// selected text only matters to the activation UI itself (Define/Save
/// Quote), not to this pipeline, which always reasons about *position*.
@MainActor
@Observable
final class BTRMenuViewModel {
    let book: Book
    let publication: Publication
    let anchorLocator: Locator
    let theme: ReaderTheme

    /// The AI features the reader has turned on for this book. The two
    /// options this view model gates on it (comprehension checks and Q&A)
    /// are hidden in the view and refuse to run when their key is missing.
    let enabledFeatures: Set<AIFeatureKey>

    /// The BTR features this menu can offer, in the order they appear.
    static let menuFeatures: [AIFeatureKey] = [
        .entityExtraction, .chapterSummary, .comprehensionCheck, .questionAnswering,
    ]

    /// The subset of `menuFeatures` turned on for `book` — master toggle,
    /// per-book override, global flag, and a usable provider/key.
    static func enabledMenuFeatures(for book: Book, modelContext: ModelContext) -> Set<AIFeatureKey> {
        let settings = AppSettingsStore.current(in: modelContext)
        return Set(menuFeatures.filter { book.isAIFeatureEnabled($0, settings) })
    }

    private(set) var activePanel: BTRActivePanel = .none

    /// The current comprehension check, once one is loaded or generated.
    private(set) var comprehensionState: BTRResultState<ComprehensionCheck> = .idle

    /// The Q&A conversation for this menu session, oldest first.
    private(set) var qaExchanges: [BTRQAExchange] = []
    var isAnsweringQuestion: Bool {
        if case .loading = qaExchanges.last?.answer { return true }
        return false
    }

    /// The read-so-far text, extracted once on the first question and
    /// reused for follow-ups — the anchor doesn't move while the menu is
    /// open, so neither does the text.
    private var readSoFarText: BTRReadSoFarTextExtractor.Result?

    private(set) var entitiesState: BTRResultState<[ExtractedEntity]> = .idle

    /// The top-half read-only preview's own navigator host (design-
    /// roadmap.md §6.6.2) — reuses `NormalReadingNavigatorController`
    /// directly, the same navigator-hosting piece Normal reading mode
    /// itself is built on, rather than the full chrome-bearing
    /// `NormalReadingView` screen (toolbar/exit/chapter-select/settings
    /// don't belong on an embedded, read-only preview pane). Deliberately
    /// *not* constructed in `init` — building a real `EPUBNavigatorViewController`
    /// is real UIKit work with no need to happen before the view is
    /// actually on screen, and keeping `init` side-effect-light keeps the
    /// pipeline tests above cheap and independent of it.
    private(set) var previewNavigatorHost: NormalReadingNavigatorController?

    /// The option currently selected (an entity chip, or the chapter-
    /// summary button) and its own pending/result state — both entity
    /// summaries and the chapter summary share this one piece of state
    /// (only one option's result is shown at a time), matching the "one
    /// shared panel" UI the design calls for.
    private(set) var selectedOptionTitle: String?
    private(set) var selectedOptionResult: BTRResultState<String> = .idle

    private let provider: AIProvider?
    private let modelContext: ModelContext
    private let wordStreamCache: WordStreamCache

    /// design-roadmap.md §6.6.3 step 1.
    private static let entityContextRadius = 100

    init(
        book: Book,
        publication: Publication,
        anchorLocator: Locator,
        provider: AIProvider?,
        enabledFeatures: Set<AIFeatureKey>,
        modelContext: ModelContext,
        wordStreamCache: WordStreamCache = WordStreamCache()
    ) {
        self.book = book
        self.publication = publication
        self.anchorLocator = anchorLocator
        self.provider = provider
        self.enabledFeatures = enabledFeatures
        self.modelContext = modelContext
        self.wordStreamCache = wordStreamCache
        theme = book.effectiveTheme(AppSettingsStore.current(in: modelContext))
    }

    /// Builds the preview pane's navigator, if it doesn't exist yet — safe
    /// to call repeatedly (e.g. from the view's `.task`, which can re-run).
    /// Failure here (a malformed publication) leaves the preview pane
    /// simply blank rather than blocking the rest of the menu, which
    /// doesn't depend on it.
    func preparePreview() {
        guard previewNavigatorHost == nil else { return }
        let layout = book.effectiveReaderSettings(AppSettingsStore.current(in: modelContext)).normalMode.layout
        previewNavigatorHost = try? NormalReadingNavigatorController(
            publication: publication, initialLocation: anchorLocator, theme: theme, layout: layout,
            // No BTR entry on the embedded preview's own selection menu —
            // selecting text there and tapping BTR would open a second BTR
            // menu on top of this one.
            includesCustomActions: false)
    }

    // MARK: - Step 1 — entity extraction (§6.6.3)

    /// Fires automatically once, when the menu opens — safe to call
    /// multiple times (e.g. from `.task`'s re-run on view identity change);
    /// only the first call past `.idle` actually does anything.
    func loadEntities() async {
        guard case .idle = entitiesState else { return }

        guard let provider else {
            entitiesState = .failed(BTRMenuViewModel.noProviderMessage)
            return
        }

        entitiesState = .loading

        guard
            let contextText = await BTRContextWindow.snippet(
                around: anchorLocator, in: publication, cache: wordStreamCache, radius: Self.entityContextRadius)
        else {
            entitiesState = .failed("Couldn't find any text around this position.")
            return
        }

        do {
            let prompt = PromptBuilder.entityExtractionPrompt(bookTitle: book.title, contextText: contextText)
            let responseText = try await provider.generateText(
                prompt: prompt, responseSchema: .json(schema: PromptBuilder.entityExtractionSchema))
            guard let data = responseText.data(using: .utf8) else { throw AIProviderError.decodingFailed }
            let decoded = try JSONDecoder().decode(EntityExtractionResponse.self, from: data)
            entitiesState = .result(decoded.entities)
        } catch {
            entitiesState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Step 2 — entity summary (§6.6.3)

    func selectEntity(_ entity: ExtractedEntity) async {
        activePanel = .textResult
        selectedOptionTitle = entity.name
        selectedOptionResult = .loading

        // Dedup: an existing profile means no new API call at all.
        let canonicalName = EntityProfile.canonicalize(entity.name)
        if let existing = book.entityProfiles.first(where: { $0.canonicalName == canonicalName }) {
            selectedOptionResult = .result(existing.summary)
            return
        }

        guard let provider else {
            selectedOptionResult = .failed(BTRMenuViewModel.noProviderMessage)
            return
        }

        let snippets = await BTREntityContextGatherer.gatherSnippets(
            forEntityNamed: entity.name, upThroughResourceHref: anchorLocator.href.string, in: publication)
        guard !snippets.isEmpty else {
            selectedOptionResult = .failed("Couldn't find any mentions of \"\(entity.name)\" yet.")
            return
        }

        do {
            let prompt = PromptBuilder.entitySummaryPrompt(
                bookTitle: book.title, entityName: entity.name, kind: entity.kind, snippets: snippets)
            let summary = try await provider.generateText(prompt: prompt, responseSchema: .plainText)

            let profile = EntityProfile(
                displayName: entity.name,
                kind: entity.kind,
                summary: summary,
                firstMentionLocatorJSON: (try? anchorLocator.jsonString()) ?? "",
                book: book
            )
            modelContext.insert(profile)
            try? modelContext.save()

            selectedOptionResult = .result(summary)
        } catch {
            selectedOptionResult = .failed(error.localizedDescription)
        }
    }

    // MARK: - "Summarize since start of chapter" (§6.6.4)

    func summarizeChapter() async {
        activePanel = .textResult
        selectedOptionTitle = "Summary So Far"
        selectedOptionResult = .loading

        let chapterHref = anchorLocator.href.string
        if let cached = book.chapterSummaries.first(where: { $0.chapterHref == chapterHref }), !isStale(cached) {
            selectedOptionResult = .result(cached.content)
            return
        }

        guard let provider else {
            selectedOptionResult = .failed(BTRMenuViewModel.noProviderMessage)
            return
        }

        guard let chapterText = await BTRChapterTextExtractor.extractText(upTo: anchorLocator, in: publication) else {
            selectedOptionResult = .failed("Couldn't find any text in this chapter.")
            return
        }

        do {
            let prompt = PromptBuilder.chapterSummaryPrompt(bookTitle: book.title, chapterText: chapterText)
            let summary = try await provider.generateText(prompt: prompt, responseSchema: .plainText)
            let locatorJSON = (try? anchorLocator.jsonString()) ?? ""

            if let existing = book.chapterSummaries.first(where: { $0.chapterHref == chapterHref }) {
                existing.content = summary
                existing.sourceEndLocatorJSON = locatorJSON
                existing.generatedAt = .now
            } else {
                let newSummary = ChapterSummary(
                    chapterHref: chapterHref, content: summary, sourceEndLocatorJSON: locatorJSON, book: book)
                modelContext.insert(newSummary)
            }
            try? modelContext.save()

            selectedOptionResult = .result(summary)
        } catch {
            selectedOptionResult = .failed(error.localizedDescription)
        }
    }

    /// Reuse a cached summary as long as the reader's current position is
    /// at or before what it covers; regenerate once they've read further
    /// into the same chapter (design-roadmap.md §2.9's staleness rule). An
    /// unparseable cached locator/missing progression is treated as stale
    /// defensively rather than trusted.
    private func isStale(_ summary: ChapterSummary) -> Bool {
        isStale(sourceEndLocatorJSON: summary.sourceEndLocatorJSON)
    }

    private func isStale(sourceEndLocatorJSON: String) -> Bool {
        guard
            let cachedLocator = try? Locator(jsonString: sourceEndLocatorJSON),
            let cachedProgression = cachedLocator.locations.progression
        else {
            return true
        }
        let currentProgression = anchorLocator.locations.progression ?? 0
        return currentProgression > cachedProgression
    }

    // MARK: - Comprehension check (dev.md §3)

    /// Shows a comprehension check for the current chapter. Reuses the most
    /// recent saved check for this chapter if it still covers the reader's
    /// position (same staleness rule as chapter summaries), so reopening
    /// the menu shows the reader's earlier answers instead of new
    /// questions. `forceNew` skips that and always generates a fresh set.
    func startComprehensionCheck(forceNew: Bool = false) async {
        guard enabledFeatures.contains(.comprehensionCheck) else { return }
        activePanel = .comprehensionCheck
        comprehensionState = .loading

        let chapterHref = anchorLocator.href.string
        if !forceNew,
            let cached = book.comprehensionChecks
                .filter({ $0.chapterHref == chapterHref })
                .max(by: { $0.generatedAt < $1.generatedAt }),
            !isStale(sourceEndLocatorJSON: cached.sourceEndLocatorJSON)
        {
            comprehensionState = .result(cached)
            return
        }

        guard let provider else {
            comprehensionState = .failed(BTRMenuViewModel.noProviderMessage)
            return
        }

        guard let chapterText = await BTRChapterTextExtractor.extractText(upTo: anchorLocator, in: publication) else {
            comprehensionState = .failed("Couldn't find any text in this chapter.")
            return
        }

        do {
            let prompt = PromptBuilder.comprehensionCheckPrompt(bookTitle: book.title, chapterText: chapterText)
            let responseText = try await provider.generateText(
                prompt: prompt, responseSchema: .json(schema: PromptBuilder.comprehensionCheckSchema))
            guard let data = responseText.data(using: .utf8) else { throw AIProviderError.decodingFailed }
            let decoded = try JSONDecoder().decode(ComprehensionCheckResponse.self, from: data)

            // Drop anything malformed, and never trust a stray pre-filled
            // answer from the model.
            let questions = decoded.questions
                .filter(\.isWellFormed)
                .prefix(PromptBuilder.comprehensionQuestionCount)
                .map { question -> ComprehensionQuestion in
                    var cleaned = question
                    cleaned.selectedChoiceIndex = nil
                    return cleaned
                }
            guard !questions.isEmpty else { throw AIProviderError.decodingFailed }

            let check = ComprehensionCheck(
                chapterHref: chapterHref,
                sourceEndLocatorJSON: (try? anchorLocator.jsonString()) ?? "",
                questions: Array(questions),
                book: book
            )
            modelContext.insert(check)
            try? modelContext.save()

            comprehensionState = .result(check)
        } catch {
            comprehensionState = .failed(error.localizedDescription)
        }
    }

    /// Records the reader's answer to one question of the current check.
    func answerComprehensionQuestion(at questionIndex: Int, choiceIndex: Int) {
        guard case .result(let check) = comprehensionState else { return }
        if check.recordAnswer(questionIndex: questionIndex, choiceIndex: choiceIndex) {
            try? modelContext.save()
        }
    }

    // MARK: - Q&A (dev.md §3)

    /// Opens the Q&A panel without sending anything yet.
    func openQuestionAnswering() {
        guard enabledFeatures.contains(.questionAnswering) else { return }
        activePanel = .questionAnswering
    }

    /// Answers a question about the book using only the text from the
    /// start of the book up to the anchor position, so answers can't spoil
    /// anything ahead (dev.md §3). Earlier exchanges in this session are
    /// passed along so follow-up questions make sense.
    func askQuestion(_ rawQuestion: String) async {
        guard enabledFeatures.contains(.questionAnswering) else { return }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnsweringQuestion else { return }

        activePanel = .questionAnswering
        let history: [PromptBuilder.QAHistoryItem] = qaExchanges.compactMap { exchange in
            guard case .result(let answer) = exchange.answer else { return nil }
            return PromptBuilder.QAHistoryItem(question: exchange.question, answer: answer)
        }
        let exchange = BTRQAExchange(question: question)
        qaExchanges.append(exchange)

        guard let provider else {
            setAnswer(.failed(BTRMenuViewModel.noProviderMessage), for: exchange.id)
            return
        }

        if readSoFarText == nil {
            readSoFarText = await BTRReadSoFarTextExtractor.extractText(upTo: anchorLocator, in: publication)
        }
        guard let readSoFarText else {
            setAnswer(.failed("Couldn't find any text up to this point."), for: exchange.id)
            return
        }

        do {
            let prompt = PromptBuilder.questionAnsweringPrompt(
                bookTitle: book.title,
                textSoFar: readSoFarText.text,
                textWasTruncated: readSoFarText.wasTruncated,
                history: history,
                question: question
            )
            let answer = try await provider.generateText(prompt: prompt, responseSchema: .plainText)
            setAnswer(.result(answer.trimmingCharacters(in: .whitespacesAndNewlines)), for: exchange.id)
        } catch {
            setAnswer(.failed(error.localizedDescription), for: exchange.id)
        }
    }

    private func setAnswer(_ answer: BTRResultState<String>, for exchangeID: UUID) {
        guard let index = qaExchanges.firstIndex(where: { $0.id == exchangeID }) else { return }
        qaExchanges[index].answer = answer
    }

    private static let noProviderMessage = "AI features aren't set up — add a provider and API key in Settings."
}
