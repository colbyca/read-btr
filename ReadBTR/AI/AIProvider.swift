import Foundation

/// The one interface every AI feature in the app goes through (design-
/// roadmap.md §2.8, §7.6). `GeminiProvider` is the only conformance for
/// MVP; adding a second backend is one new conformance plus one case in
/// `AIProviderKind` — nothing else in the app needs to change.
protocol AIProvider: Sendable {
    /// - Parameters:
    ///   - prompt: The full prompt text — callers (`PromptBuilder`) are
    ///     responsible for embedding any context/instructions; this
    ///     protocol doesn't do templating itself.
    ///   - responseSchema: `nil`/`.plainText` for free-form prose (chapter
    ///     summaries, entity summaries); `.json(schema:)` for a structured
    ///     extraction the caller intends to decode (entity extraction) —
    ///     reliability over flexibility for that one fixed, well-defined
    ///     task (design-roadmap.md §6.6.3).
    func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String
}

/// Mirrors Gemini's `responseMimeType`/`responseSchema` generation config
/// (design-roadmap.md §2.8) — kept provider-agnostic in shape (a plain
/// `[String: Any]` JSON Schema-ish dict, not a Gemini-specific type) so a
/// future second provider isn't forced into Gemini's exact request shape.
/// `@unchecked Sendable`: `[String: Any]` isn't provably `Sendable`, but a
/// schema dict is built once (`PromptBuilder.entityExtractionSchema`) and
/// only ever read afterward — never mutated after crossing into
/// `AIProvider.generateText`'s nonisolated context, so this is safe in
/// practice even though the compiler can't verify it structurally.
enum AIResponseSchema: @unchecked Sendable {
    case plainText
    case json(schema: [String: Any])
}

/// Typed failures every `AIProvider` conformance should raise through,
/// rather than letting raw `URLError`/decoding errors leak to call sites —
/// `BTRMenuViewModel` needs to show the user something readable regardless
/// of which provider is behind the interface.
enum AIProviderError: Error, LocalizedError, Equatable {
    /// No provider selected, or no Keychain key for the selected provider —
    /// "If a provider or key is not given, AI features should be disabled"
    /// (design-roadmap.md §6.2). Call sites should generally catch this
    /// *before* ever reaching a provider (`AIProviderFactory.makeProvider`
    /// returning `nil`), but conformances still raise it defensively if
    /// constructed with an empty key directly.
    case missingAPIKey
    case httpError(status: Int, body: String)
    case emptyResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key is configured for this AI provider."
        case .httpError(let status, let body):
            "The AI provider returned an error (\(status)): \(body)"
        case .emptyResponse:
            "The AI provider returned an empty response."
        case .decodingFailed:
            "Couldn't understand the AI provider's response."
        }
    }
}
