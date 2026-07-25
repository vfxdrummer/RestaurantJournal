import Foundation

/// Whether the user wants their journal backed up to iCloud. Read at launch by the app's container
/// builder (SwiftData fixes the CloudKit setting at container-creation time, so a change takes
/// effect on the next app launch, not live). Defaults to on.
enum SyncPreference {
    static let key = "iCloudSyncEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
