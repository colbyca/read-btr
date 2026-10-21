import Foundation
import SwiftData

/// One multiple-choice question inside a `ComprehensionCheck`. Decoded
/// straight from the AI provider's structured JSON output
/// (`PromptBuilder.comprehensionCheckSchema`), then stored on the check with
/// the reader's own answer filled in as they go.
struct ComprehensionQuestion: Codable, Equatable {
    var question: String
    var choices: [String]
    var correctChoiceIndex: Int
    var explanation: String

    /// nil until the reader picks a choice. Not part of the AI response.
    var selectedChoiceIndex: Int?

    var isAnswered: Bool { selectedChoiceIndex != nil }
    var isAnsweredCorrectly: Bool { selectedChoiceIndex == correctChoiceIndex }

    /// A question is only usable if it has at least two choices and its
    /// correct index actually points at one of them — anything else from the
    /// model gets dropped rather than shown broken.
    var isWellFormed: Bool {
        !question.isEmpty && choices.count >= 2 && choices.indices.contains(correctChoiceIndex)
    }
}

/// A set of AI-generated comprehension questions about one chapter, plus
/// the reader's answers (dev.md §3: "generate N questions from the
/// just-finished chapter/section; results stored locally (SwiftData) so
/// they could feed a 'review what you've read' feature later").
///
/// "Chapter" == Readium spine item, same as `ChapterSummary`. The questions
/// only cover the chapter up to `sourceEndLocatorJSON`, so a check made
/// mid-chapter never asks about text the reader hasn't reached.
@Model
final class ComprehensionCheck {
    var id: UUID
    var chapterHref: String
    var chapterTitle: String?

    /// How far into the chapter the questions cover — same staleness key
    /// as `ChapterSummary.sourceEndLocatorJSON`.
    var sourceEndLocatorJSON: String

    var questions: [ComprehensionQuestion]
    var generatedAt: Date

    /// Set once every question has an answer.
    var completedAt: Date?

    var book: Book?

    init(
        id: UUID = UUID(),
        chapterHref: String,
        chapterTitle: String? = nil,
        sourceEndLocatorJSON: String,
        questions: [ComprehensionQuestion],
        generatedAt: Date = .now,
        completedAt: Date? = nil,
        book: Book? = nil
    ) {
        self.id = id
        self.chapterHref = chapterHref
        self.chapterTitle = chapterTitle
        self.sourceEndLocatorJSON = sourceEndLocatorJSON
        self.questions = questions
        self.generatedAt = generatedAt
        self.completedAt = completedAt
        self.book = book
    }
}

extension ComprehensionCheck {
    var answeredCount: Int { questions.filter(\.isAnswered).count }
    var correctCount: Int { questions.filter(\.isAnsweredCorrectly).count }
    var isComplete: Bool { !questions.isEmpty && answeredCount == questions.count }

    /// Records the reader's pick for one question. First answer wins — a
    /// question already answered is left alone, so the score can't be
    /// gamed by retrying. Returns whether anything changed.
    @discardableResult
    func recordAnswer(questionIndex: Int, choiceIndex: Int) -> Bool {
        guard questions.indices.contains(questionIndex) else { return false }
        guard questions[questionIndex].choices.indices.contains(choiceIndex) else { return false }
        guard !questions[questionIndex].isAnswered else { return false }

        // Reassign the whole array so SwiftData sees the change to this
        // Codable attribute.
        var updated = questions
        updated[questionIndex].selectedChoiceIndex = choiceIndex
        questions = updated

        if isComplete, completedAt == nil {
            completedAt = .now
        }
        return true
    }
}
