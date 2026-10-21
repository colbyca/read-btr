import SwiftUI

/// The Q&A panel in the BTR menu: ask a question about the book and get an
/// answer drawn only from what the reader has read so far. Shows the
/// session's earlier questions and answers above the input field.
struct BTRQuestionAnsweringPanel: View {
    let exchanges: [BTRQAExchange]
    let isAnswering: Bool
    let onAsk: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask About the Book")
                .font(.headline)
                .accessibilityIdentifier("btr-qa-title")

            if exchanges.isEmpty {
                Text("Answers only use what you've read so far, so they won't spoil anything ahead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(exchanges) { exchange in
                VStack(alignment: .leading, spacing: 4) {
                    Text(exchange.question)
                        .font(.subheadline.weight(.semibold))
                    switch exchange.answer {
                    case .idle:
                        EmptyView()
                    case .loading:
                        ProgressView()
                            .accessibilityIdentifier("btr-qa-loading")
                    case .result(let answer):
                        Text(answer)
                            .accessibilityIdentifier("btr-qa-answer")
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("btr-qa-error")
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask a question…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier("btr-qa-input")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("btr-qa-send")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if exchanges.isEmpty { isFieldFocused = true }
        }
    }

    private var canSend: Bool {
        !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        onAsk(draft)
        draft = ""
    }
}
