import Foundation
import Testing

@testable import ReadBTR

@MainActor
struct ComprehensionCheckTests {
    private static func makeCheck() -> ComprehensionCheck {
        ComprehensionCheck(
            chapterHref: "chapter1.xhtml", sourceEndLocatorJSON: "{}",
            questions: [
                ComprehensionQuestion(question: "Q1?", choices: ["A", "B"], correctChoiceIndex: 0, explanation: "A."),
                ComprehensionQuestion(question: "Q2?", choices: ["A", "B"], correctChoiceIndex: 1, explanation: "B."),
            ])
    }

    @Test func recordAnswerKeepsTheFirstAnswerOnly() {
        let check = Self.makeCheck()
        #expect(check.recordAnswer(questionIndex: 0, choiceIndex: 1))
        #expect(!check.recordAnswer(questionIndex: 0, choiceIndex: 0))
        #expect(check.questions[0].selectedChoiceIndex == 1)
        #expect(check.answeredCount == 1)
        #expect(check.correctCount == 0)
        #expect(!check.isComplete)
        #expect(check.completedAt == nil)
    }

    @Test func recordAnswerRejectsOutOfRangeIndexes() {
        let check = Self.makeCheck()
        #expect(!check.recordAnswer(questionIndex: 5, choiceIndex: 0))
        #expect(!check.recordAnswer(questionIndex: 0, choiceIndex: 9))
        #expect(check.answeredCount == 0)
    }

    @Test func answeringAllQuestionsSetsCompletedAt() {
        let check = Self.makeCheck()
        check.recordAnswer(questionIndex: 0, choiceIndex: 0)
        check.recordAnswer(questionIndex: 1, choiceIndex: 1)
        #expect(check.isComplete)
        #expect(check.correctCount == 2)
        #expect(check.completedAt != nil)
    }

    @Test func malformedQuestionsAreNotWellFormed() {
        #expect(!ComprehensionQuestion(question: "", choices: ["A", "B"], correctChoiceIndex: 0, explanation: "").isWellFormed)
        #expect(!ComprehensionQuestion(question: "Q?", choices: ["A"], correctChoiceIndex: 0, explanation: "").isWellFormed)
        #expect(!ComprehensionQuestion(question: "Q?", choices: ["A", "B"], correctChoiceIndex: 2, explanation: "").isWellFormed)
        #expect(!ComprehensionQuestion(question: "Q?", choices: ["A", "B"], correctChoiceIndex: -1, explanation: "").isWellFormed)
    }
}
