import Foundation

/// Minimal client for the OpenAI Chat Completions API (ChatGPT models).
struct OpenAIClient: LLMCompleting {
    let apiKey: String
    var model: String = "gpt-4o-mini"

    /// Reads `OPENAI_API_KEY` from the environment (set in the run scheme). Returns `nil` if unset.
    static func fromEnvironment() -> OpenAIClient? {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return OpenAIClient(apiKey: key)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw NSError(domain: "OpenAIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        struct APIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }
}
