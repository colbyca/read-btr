import Foundation
import Testing

@testable import ReadBTR

struct AIProviderFactoryTests {
    @Test func returnsNilWhenNoProviderSelected() {
        let settings = AppSettings(aiProvider: nil)
        let provider = AIProviderFactory.makeProvider(settings: settings, keyStore: ModelsTests.FakeAIKeyStore())
        #expect(provider == nil)
    }

    @Test func returnsNilWhenProviderSelectedButNoKeyStored() {
        let settings = AppSettings(aiProvider: .gemini)
        let provider = AIProviderFactory.makeProvider(settings: settings, keyStore: ModelsTests.FakeAIKeyStore())
        #expect(provider == nil)
    }

    @Test func returnsGeminiProviderWhenSelectedAndKeyed() throws {
        let settings = AppSettings(aiProvider: .gemini)
        let keyStore = ModelsTests.FakeAIKeyStore(keys: [.gemini: "test-key"])
        let provider = try #require(AIProviderFactory.makeProvider(settings: settings, keyStore: keyStore))

        let gemini = try #require(provider as? GeminiProvider)
        #expect(gemini.apiKey == "test-key")
    }
}
