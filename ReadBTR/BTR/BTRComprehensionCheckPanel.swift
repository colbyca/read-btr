import SwiftUI

/// The comprehension-check panel in the BTR menu: a few multiple-choice
/// questions about the chapter so far. Tapping a choice locks in the
/// answer, marks it right or wrong, and shows the explanation. The score
/// shows once every question is answered.
struct BTRComprehensionCheckPanel: View {
    let state: BTRResultState<ComprehensionCheck>
    let onAnswer: (_ questionIndex: Int, _ choiceIndex: Int) -> Void
    let onNewQuestions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Your Understanding")
                .font(.headline)
                .accessibilityIdentifier("btr-comprehension-title")

            switch state {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Writing questions about this chapter…")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .accessibilityIdentifier("btr-comprehension-loading")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("btr-comprehension-error")
            case .result(let check):
                questionList(check)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func questionList(_ check: ComprehensionCheck) -> some View {
        ForEach(Array(check.questions.enumerated()), id: \.offset) { questionIndex, question in
            VStack(alignment: .leading, spacing: 8) {
                Text("\(questionIndex + 1). \(question.question)")
                    .font(.subheadline.weight(.semibold))

                ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    choiceButton(
                        question: question, choice: choice, choiceIndex: choiceIndex, questionIndex: questionIndex)
                }

                if question.isAnswered {
                    Text(question.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("btr-comprehension-explanation-\(questionIndex)")
                }
            }
            .padding(.bottom, 4)
        }

        if check.isComplete {
            HStack {
                Text("You got \(check.correctCount) of \(check.questions.count) right.")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("btr-comprehension-score")
                Spacer()
                Button("New Questions", action: onNewQuestions)
                    .font(.subheadline)
                    .accessibilityIdentifier("btr-comprehension-new")
            }
        }
    }

    private func choiceButton(
        question: ComprehensionQuestion, choice: String, choiceIndex: Int, questionIndex: Int
    ) -> some View {
        let status = ChoiceStatus(question: question, choiceIndex: choiceIndex)
        return Button {
            onAnswer(questionIndex, choiceIndex)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.tint)
                Text(choice)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(status.tint.opacity(status == .unanswered ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(question.isAnswered)
        .accessibilityIdentifier("btr-comprehension-choice-\(questionIndex)-\(choiceIndex)")
        .accessibilityValue(status.accessibilityValue)
    }

    /// How one choice should look once the question is (or isn't yet)
    /// answered.
    private enum ChoiceStatus: Equatable {
        case unanswered
        case correct
        case wrongPick
        case other

        init(question: ComprehensionQuestion, choiceIndex: Int) {
            guard let selected = question.selectedChoiceIndex else {
                self = .unanswered
                return
            }
            if choiceIndex == question.correctChoiceIndex {
                self = .correct
            } else if choiceIndex == selected {
                self = .wrongPick
            } else {
                self = .other
            }
        }

        var symbolName: String {
            switch self {
            case .unanswered, .other: "circle"
            case .correct: "checkmark.circle.fill"
            case .wrongPick: "xmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .unanswered, .other: .secondary
            case .correct: .green
            case .wrongPick: .red
            }
        }

        var accessibilityValue: String {
            switch self {
            case .unanswered, .other: ""
            case .correct: "Correct answer"
            case .wrongPick: "Your answer, incorrect"
            }
        }
    }
}
