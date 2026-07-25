import SwiftUI

/// Lightweight settings for the account-free (App Store) build: iCloud backup, the anonymous-analytics
/// opt-out, and a link to the privacy policy. In `CARD_LINKING` builds the full ProfileView is shown
/// instead (it embeds the same iCloud backup section).
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var analyticsEnabled = Analytics.isEnabled

    private let privacyURL = URL(string: "https://restaurant-journal.com/privacy")!

    var body: some View {
        NavigationStack {
            Form {
                CloudBackupSectionView()

                Section {
                    Toggle("Share anonymous usage data", isOn: $analyticsEnabled)
                        .onChange(of: analyticsEnabled) { _, newValue in
                            Analytics.isEnabled = newValue
                        }
                } footer: {
                    Text("Helps us improve the app. Always anonymous — never tied to your identity, photos, or notes. You can turn this off anytime.")
                }

                Section {
                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
