import Foundation

/// Minimal client for the Anthropic Messages API, shared by journal features that call Claude.
struct ClaudeClient {
    let apiKey: String
    var model: String = "claude-sonnet-4-6"

    /// Reads `ANTHROPIC_API_KEY` from the environment (set in the run scheme). Returns `nil` if
    /// unset, so callers can fall back to non-AI behavior.
    static func fromEnvironment() -> ClaudeClient? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            return nil
        }
        return ClaudeClient(apiKey: key)
    }

    func complete(system: String, user: String, maxTokens: Int = 1024) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw NSError(domain: "ClaudeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        struct APIResponse: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        return decoded.content.compactMap { $0.text }.joined(separator: "\n")
    }
}
