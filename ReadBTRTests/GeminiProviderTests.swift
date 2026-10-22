import Foundation
import Testing

@testable import ReadBTR

struct GeminiProviderTests {
    /// Records the last request it was asked to perform and returns a
    /// canned response — `GeminiProvider.session` accepts anything
    /// conforming to `URLRequestPerforming`, so this stands in for
    /// `URLSession` without a real network call or global `URLProtocol`
    /// registration.
    final class FakeSession: URLRequestPerforming, @unchecked Sendable {
        var lastRequest: URLRequest?
        var responseData = Data()
        var statusCode = 200

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lastRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (responseData, response)
        }
    }

    private static func candidateResponse(text: String) -> Data {
        let json: [String: Any] = [
            "candidates": [
                ["content": ["parts": [["text": text]]]]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    @Test func plainTextRequestOmitsGenerationConfig() async throws {
        let session = FakeSession()
        session.responseData = Self.candidateResponse(text: "hello")
        let provider = GeminiProvider(apiKey: "test-key", session: session)

        let result = try await provider.generateText(prompt: "say hello", responseSchema: .plainText)

        #expect(result == "hello")
        let body = try #require(session.lastRequest?.httpBody)
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["generationConfig"] == nil)

        let contents = try #require(decoded["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "say hello")
    }

    @Test func jsonSchemaRequestSetsResponseMimeTypeAndSchema() async throws {
        let session = FakeSession()
        session.responseData = Self.candidateResponse(text: #"{"entities":[]}"#)
        let provider = GeminiProvider(apiKey: "test-key", session: session)

        let schema: [String: Any] = ["type": "OBJECT"]
        _ = try await provider.generateText(prompt: "extract entities", responseSchema: .json(schema: schema))

        let body = try #require(session.lastRequest?.httpBody)
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let generationConfig = try #require(decoded["generationConfig"] as? [String: Any])
        #expect(generationConfig["responseMimeType"] as? String == "application/json")
        #expect((generationConfig["responseSchema"] as? [String: Any])?["type"] as? String == "OBJECT")
    }

    @Test func requestIncludesAPIKeyAndModelInURL() async throws {
        let session = FakeSession()
        session.responseData = Self.candidateResponse(text: "ok")
        var provider = GeminiProvider(apiKey: "abc123", session: session)
        provider.model = "gemini-3.8-flash"

        _ = try await provider.generateText(prompt: "hi", responseSchema: nil)

        let url = try #require(session.lastRequest?.url?.absoluteString)
        #expect(url.contains("gemini-3.8-flash:generateContent"))
        #expect(url.contains("key=abc123"))
    }

    @Test func emptyAPIKeyThrowsMissingAPIKeyWithoutMakingARequest() async throws {
        let session = FakeSession()
        let provider = GeminiProvider(apiKey: "", session: session)

        await #expect(throws: AIProviderError.missingAPIKey) {
            _ = try await provider.generateText(prompt: "hi", responseSchema: nil)
        }
        #expect(session.lastRequest == nil)
    }

    @Test func nonSuccessStatusThrowsHTTPError() async throws {
        let session = FakeSession()
        session.statusCode = 429
        session.responseData = Data("rate limited".utf8)
        let provider = GeminiProvider(apiKey: "test-key", session: session)

        await #expect(throws: AIProviderError.httpError(status: 429, body: "rate limited")) {
            _ = try await provider.generateText(prompt: "hi", responseSchema: nil)
        }
    }

    @Test func malformedResponseThrowsEmptyResponse() async throws {
        let session = FakeSession()
        session.responseData = Data("{}".utf8)
        let provider = GeminiProvider(apiKey: "test-key", session: session)

        await #expect(throws: AIProviderError.emptyResponse) {
            _ = try await provider.generateText(prompt: "hi", responseSchema: nil)
        }
    }
}
