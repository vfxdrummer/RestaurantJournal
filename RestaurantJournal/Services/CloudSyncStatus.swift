import Foundation
import CloudKit
import CoreData
import Observation

/// Reports whether the user's journal is backing up to their **private iCloud**, for display in
/// Settings. SwiftData syncs via `NSPersistentCloudKitContainer` under the hood, so this:
///   1. checks the CloudKit **account status** (is there an iCloud account to sync to?), and
///   2. observes CloudKit **sync events** to show activity, last-backed-up time, and any error.
///
/// Safe in every build: if the iCloud capability isn't provisioned or there's no account, it simply
/// reports `.unavailable` / `.noAccount` and never throws.
@MainActor
@Observable
final class CloudSyncStatus {
    static let shared = CloudSyncStatus()

    enum Account {
        case checking, available, noAccount, restricted, unavailable
    }

    private(set) var account: Account = .checking
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?

    private var eventObserver: NSObjectProtocol?

    private init() {
        startObservingSyncEvents()
    }

    /// Ask CloudKit whether an iCloud account is available. Safe to call repeatedly (e.g. onAppear).
    func refresh() async {
        let container = CKContainer(identifier: RestaurantJournalApp.cloudKitContainerID)
        do {
            switch try await container.accountStatus() {
            case .available: account = .available
            case .noAccount: account = .noAccount
            case .restricted: account = .restricted
            case .couldNotDetermine, .temporarilyUnavailable: account = .unavailable
            @unknown default: account = .unavailable
            }
        } catch {
            account = .unavailable
        }
    }

    private func startObservingSyncEvents() {
        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event
            else { return }
            // Delivered on the main queue, so main-actor isolation holds.
            MainActor.assumeIsolated { self?.apply(event) }
        }
    }

    private func apply(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: String
        switch event.type {
        case .setup: kind = "setup"
        case .import: kind = "import"
        case .export: kind = "export"
        @unknown default: kind = "event"
        }
        // A nil endDate means the operation is still in flight.
        if event.endDate == nil {
            isSyncing = true
            print("[iCloudSync] \(kind) started")
            return
        }
        isSyncing = false
        if event.succeeded {
            lastErrorMessage = nil
            // Track the last successful *upload* as "backed up".
            if event.type == .export { lastSyncDate = event.endDate }
            print("[iCloudSync] \(kind) finished OK")
        } else if let error = event.error {
            lastErrorMessage = error.localizedDescription
            print("[iCloudSync] \(kind) FAILED: \(error)")
        }
    }
}
