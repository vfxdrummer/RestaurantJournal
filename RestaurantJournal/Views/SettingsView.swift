import SwiftUI

/// Lets the user paste and securely store each provider's API key (Keychain-backed), so the app
/// doesn't depend on run-scheme environment variables.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var claudeKey = ""
    @State private var openaiKey = ""
    @State private var proxyURL = ""
    @State private var proxyToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…workers.dev", text: $proxyURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Shared token (optional)", text: $proxyToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server (recommended)")
                } footer: {
                    Text("If you deploy the proxy (see server/README.md) and paste its URL here, the app routes through it and no API keys are needed on this device. Leave blank to use your own keys below.")
                }

                Section {
                    SecureField("sk-ant-…", text: $claudeKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("From console.anthropic.com → API Keys. Entering a key uses your own account (BYOK) and overrides the server. — Currently: \(LLMProvider.claude.activeSource.label).")
                }

                Section {
                    SecureField("sk-…", text: $openaiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("ChatGPT (OpenAI) API key")
                } footer: {
                    Text("From platform.openai.com → API keys (a pay-as-you-go developer key, not your ChatGPT subscription). Entering a key overrides the server. — Currently: \(LLMProvider.openai.activeSource.label).")
                }

                Section {
                    Text("Pick which model answers in the Ask tab using the menu there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("API Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                claudeKey = APIKeyStore.savedKey(for: .claude)
                openaiKey = APIKeyStore.savedKey(for: .openai)
                proxyURL = ProxyConfig.urlString
                proxyToken = ProxyConfig.savedAppToken
            }
        }
    }

    private func save() {
        ProxyConfig.setURL(proxyURL)
        ProxyConfig.setAppToken(proxyToken)
        APIKeyStore.setKey(claudeKey, for: .claude)
        APIKeyStore.setKey(openaiKey, for: .openai)
        dismiss()
    }
}
