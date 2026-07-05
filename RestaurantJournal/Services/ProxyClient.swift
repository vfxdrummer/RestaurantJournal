import Foundation

/// Stores the optional backend proxy configuration. When a URL is set, the app routes LLM calls
/// through the proxy (which holds the API keys), so no keys live on the device.
enum ProxyConfig {
    /// Baked-in defaults so the app routes through the hosted proxy out of the box, with no setup.
    /// A user can override either in Settings, or bypass the proxy entirely by entering their own
    /// API key (BYOK takes precedence).
    static let defaultURL = "https://restaurant-journal-llm-proxy.restaurantjournal.workers.dev"
    static let defaultAppToken = "Restaurant_Journal_APP_TOKEN"

    private static let urlKey = "proxyURL"
    private static let tokenKeychainKey = "proxy.appToken"

    /// Effective URL: a user-entered override if present, otherwise the default.
    static var urlString: String {
        let saved = UserDefaults.standard.string(forKey: urlKey) ?? ""
        return saved.isEmpty ? defaultURL : saved
    }

    static var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    static func setURL(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }

    /// Effective token: a user-entered override if present, otherwise the default.
    static var appToken: String? {
        let saved = KeychainStore.load(tokenKeychainKey) ?? ""
        let effective = saved.isEmpty ? defaultAppToken : saved
        return effective.isEmpty ? nil : effective
    }

    static var savedAppToken: String {
        let saved = KeychainStore.load(tokenKeychainKey) ?? ""
        return saved.isEmpty ? defaultAppToken : saved
    }

    static func setAppToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(tokenKeychainKey)
        } else {
            KeychainStore.save(trimmed, for: tokenKeychainKey)
        }
    }

    static var isEnabled: Bool { url != nil }
}

/// Sends completions to the backend proxy instead of the provider directly. The chosen provider
/// travels in the request body; the proxy holds the actual API keys.
struct ProxyClient: LLMCompleting {
    let provider: LLMProvider
    let endpoint: URL
    let appToken: String?

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let appToken {
            request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "provider": provider.rawValue,
            "system": system,
            "user": user,
            "maxTokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw NSError(domain: "ProxyClient", code: 429, userInfo: [
                NSLocalizedDescriptionKey: "You've reached the usage limit. Please wait a minute and try again."
            ])
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Proxy request failed"
            throw NSError(domain: "ProxyClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        struct ProxyResponse: Decodable { let text: String? }
        return (try JSONDecoder().decode(ProxyResponse.self, from: data)).text ?? ""
    }
}
