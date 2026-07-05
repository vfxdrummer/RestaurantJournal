import Foundation

/// A text-in / text-out LLM backend. Both Claude and ChatGPT conform, so journal features can
/// use either interchangeably.
protocol LLMCompleting {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

extension LLMCompleting {
    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, maxTokens: 1024)
    }
}

/// The user-selectable AI provider, shared between the Ask UI and the recommendation feature.
enum LLMProvider: String, CaseIterable, Identifiable {
    case claude
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "ChatGPT"
        }
    }

    /// The environment variable that supplies this provider's API key (dev fallback).
    var envVarName: String {
        switch self {
        case .claude: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        }
    }

    /// Keychain account name for this provider's saved key.
    var keychainKey: String { "apiKey.\(rawValue)" }

    /// Where a provider's requests are currently routed.
    enum KeySource {
        case userKey       // the user entered their own key → BYOK
        case proxy         // the shared backend proxy
        case environment   // dev fallback (scheme env var)
        case none

        var label: String {
            switch self {
            case .userKey: return "Using your key"
            case .proxy: return "Using the app server"
            case .environment: return "Using the developer key"
            case .none: return "Not configured"
            }
        }
    }

    /// Resolution priority: a key the user entered wins (BYOK), then the shared proxy, then the
    /// dev environment variable.
    var activeSource: KeySource {
        if APIKeyStore.userKey(for: self) != nil { return .userKey }
        if ProxyConfig.isEnabled { return .proxy }
        if APIKeyStore.envKey(for: self) != nil { return .environment }
        return .none
    }

    var isConfigured: Bool { activeSource != .none }

    /// A usable client following `activeSource` priority: a user-supplied key (BYOK) is used
    /// directly and overrides the shared proxy; otherwise the proxy; otherwise the dev env key.
    func makeClient() -> LLMCompleting? {
        if let key = APIKeyStore.userKey(for: self) {
            return directClient(key: key)
        }
        if let endpoint = ProxyConfig.url {
            return ProxyClient(provider: self, endpoint: endpoint, appToken: ProxyConfig.appToken)
        }
        if let key = APIKeyStore.envKey(for: self) {
            return directClient(key: key)
        }
        return nil
    }

    private func directClient(key: String) -> LLMCompleting {
        switch self {
        case .claude: return ClaudeClient(apiKey: key)
        case .openai: return OpenAIClient(apiKey: key)
        }
    }

    // MARK: - Persisted selection

    static let defaultsKey = "selectedLLMProvider"

    /// The currently-selected provider, backed by UserDefaults (the Ask picker writes here).
    static var selected: LLMProvider {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(LLMProvider.init(rawValue:)) ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Resolves and stores each provider's API key: a Keychain-saved key wins; otherwise the
/// environment variable (dev fallback) is used.
enum APIKeyStore {
    /// A key the user entered in Settings (Keychain). Present = BYOK is active.
    static func userKey(for provider: LLMProvider) -> String? {
        let key = KeychainStore.load(provider.keychainKey) ?? ""
        return key.isEmpty ? nil : key
    }

    /// The scheme environment variable key (developer fallback only).
    static func envKey(for provider: LLMProvider) -> String? {
        let key = ProcessInfo.processInfo.environment[provider.envVarName] ?? ""
        return key.isEmpty ? nil : key
    }

    static func key(for provider: LLMProvider) -> String? {
        userKey(for: provider) ?? envKey(for: provider)
    }

    /// The Keychain-saved key only (used to populate the Settings fields for editing).
    static func savedKey(for provider: LLMProvider) -> String {
        KeychainStore.load(provider.keychainKey) ?? ""
    }

    static func setKey(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(provider.keychainKey)
        } else {
            KeychainStore.save(trimmed, for: provider.keychainKey)
        }
    }
}
