import SwiftUI

/// The "iCloud Backup" settings block — an on/off toggle plus live sync status. Shared so it appears
/// in every build: the account-free `AppSettingsView` and the `CARD_LINKING` `ProfileView`.
struct CloudBackupSectionView: View {
    @State private var sync = CloudSyncStatus.shared
    @AppStorage(SyncPreference.key) private var syncEnabled = true

    var body: some View {
        Section {
            Toggle("Back up to iCloud", isOn: $syncEnabled)
            if syncEnabled {
                syncRow
                    .task { await sync.refresh() }
            }
        } header: {
            Text("iCloud Backup")
        } footer: {
            Text(syncFooter)
        }
    }

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
}
