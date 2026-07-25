import SwiftUI

/// Lightweight settings for the account-free (App Store) build: the anonymous-analytics opt-out and
/// a link to the privacy policy. In `CARD_LINKING` builds the full ProfileView is shown instead.
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var analyticsEnabled = Analytics.isEnabled
    @State private var sync = CloudSyncStatus.shared
    @AppStorage(SyncPreference.key) private var syncEnabled = true

    private let privacyURL = URL(string: "https://restaurant-journal.com/privacy")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Back up to iCloud", isOn: $syncEnabled)
                    if syncEnabled {
                        syncRow
                    }
                } header: {
                    Text("iCloud Backup")
                } footer: {
                    Text(syncFooter)
                }

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
            .task { await sync.refresh() }
        }
    }

    // MARK: - iCloud sync status row

    @ViewBuilder
    private var syncRow: some View {
        HStack(spacing: 12) {
            Image(systemName: syncIcon)
                .font(.title3)
                .foregroundStyle(syncTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(syncTitle)
                if let subtitle = syncSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if sync.isSyncing {
                ProgressView()
            }
        }
    }

    private var syncFooter: String {
        if syncEnabled {
            return "Your journal is stored privately in your own iCloud — restaurants, ratings, notes and voice memos. It restores automatically when you reinstall the app or set up a new iPhone. Nothing is shared with us or anyone else. Reopen the app after changing this for it to take effect."
        } else {
            return "Backup is off — your journal stays only on this iPhone and won't restore if you delete the app or switch phones. Reopen the app after turning this on to start backing up."
        }
    }

    private var syncTitle: String {
        switch sync.account {
        case .checking: return "Checking iCloud…"
        case .available: return sync.lastErrorMessage == nil ? "Backing up to iCloud" : "Backup issue"
        case .noAccount: return "Not signed in to iCloud"
        case .restricted: return "iCloud is restricted"
        case .unavailable: return "iCloud unavailable"
        }
    }

    private var syncSubtitle: String? {
        switch sync.account {
        case .checking:
            return nil
        case .available:
            if let message = sync.lastErrorMessage { return "\(message) — will retry automatically." }
            if let date = sync.lastSyncDate {
                return "Last backed up \(date.formatted(.relative(presentation: .named)))."
            }
            return "Your journal syncs automatically."
        case .noAccount:
            return "Sign in to iCloud in the Settings app to back up and restore your journal."
        case .restricted:
            return "iCloud access is restricted on this device, so backup is off."
        case .unavailable:
            return "Backup will resume automatically once iCloud is reachable."
        }
    }

    private var syncIcon: String {
        switch sync.account {
        case .checking: return "arrow.triangle.2.circlepath.icloud"
        case .available: return sync.lastErrorMessage == nil ? "checkmark.icloud" : "exclamationmark.icloud"
        case .noAccount, .unavailable: return "icloud.slash"
        case .restricted: return "lock.icloud"
        }
    }

    private var syncTint: Color {
        switch sync.account {
        case .available where sync.lastErrorMessage == nil: return .green
        case .checking: return .secondary
        default: return .orange
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
