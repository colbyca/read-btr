#if DEBUG
import Foundation
import SwiftData

/// Debug-only switches UI tests flip with launch arguments. Compiled out
/// of Release builds entirely.
enum UITestHooks {
    /// Turns the BTR chat on with a fake API key and a canned provider, so
    /// UI tests can open the chat and see a rendered reply without a real
    /// key or network.
    static let stubAIArgument = "-uitest-stub-ai"

    static var isStubbingAI: Bool {
        ProcessInfo.processInfo.arguments.contains(stubAIArgument)
    }

    /// Call once at launch, before any screen reads AI settings.
    static func installKeyStoreIfNeeded() {
        guard isStubbingAI else { return }
        AppSettings.keyStore = InMemoryKeyStore()
    }

    @MainActor
    static func configureSettingsIfNeeded(context: ModelContext) {
        guard isStubbingAI else { return }
        let settings = AppSettingsStore.current(in: context)
        settings.aiProvider = .gemini
        settings.aiFeaturesMasterToggle = true
        settings.aiFeatureFlags = [AIFeatureFlag(key: .btrChat, isEnabled: true)]
        try? context.save()
    }

    private final class InMemoryKeyStore: AIKeyStore, @unchecked Sendable {
        func key(for provider: AIProviderKind) -> String? { "uitest-stub-key" }
        func setKey(_ key: String?, for provider: AIProviderKind) {}
    }

    struct StubAIProvider: AIProvider {
        func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String {
            if case .json = responseSchema { return #"{"searchTerms":["Alice"]}"# }
            return "Stub reply."
        }

        func generateChatReply(systemPrompt: String, messages: [AIChatMessage]) async throws -> String {
            try? await Task.sleep(for: .milliseconds(300))
            return """
                ### A stub answer

                **Alice** is the curious heroine. So far she has:

                - followed the *White Rabbit*
                - fallen down the rabbit-hole

                > "Curiouser and curiouser!"
                """
        }
    }
}
#endif
