import Foundation

/// Minimal seam over `URLSession` so tests can stub network calls without
/// registering a global `URLProtocol` — `URLSession` itself already
/// satisfies this via its own `data(for:)`, so production code passes
/// nothing extra.
protocol URLRequestPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLRequestPerforming {}

/// `AIProvider` conformance for Google's Gemini API (design-roadmap.md
/// §2.7/§2.8) — the only backend for MVP. Talks directly to the
/// `generateContent` REST endpoint over `URLSession`; no SDK dependency.
struct GeminiProvider: AIProvider {
    let apiKey: String

    /// `2.5-flash` — fast/cheap, more than sufficient for the fixed,
    /// well-scoped extraction/summarization prompts this app sends
    /// (design-roadmap.md §6.6). Trivially bumped later; nothing else in
    /// the app knows this string.
    var model: String = "gemini-2.5-flash"

    var session: URLRequestPerforming = URLSession.shared

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }

        var body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]
        if case .json(let schema) = responseSchema {
            body["generationConfig"] = [
                "responseMimeType": "application/json",
                "responseSchema": schema,
            ]
        }

        guard
            let url = URL(string: "\(Self.baseURL)/\(model):generateContent?key=\(apiKey)"),
            let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else {
            throw AIProviderError.decodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.decodingFailed
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.httpError(status: httpResponse.statusCode, body: body)
        }

        guard let text = Self.extractText(from: data) else {
            throw AIProviderError.emptyResponse
        }
        return text
    }

    /// Digs `candidates[0].content.parts[0].text` out of Gemini's
    /// `generateContent` response — the one field every call site (plain
    /// text or structured JSON alike) actually needs; the structured-output
    /// case just means that string is itself a JSON document, decoded one
    /// layer up by the caller, not here.
    private static func extractText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String,
            !text.isEmpty
        else {
            return nil
        }
        return text
    }
}
