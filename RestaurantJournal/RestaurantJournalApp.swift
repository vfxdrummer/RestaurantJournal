import SwiftUI
import SwiftData

@main
struct RestaurantJournalApp: App {
    let sharedModelContainer: ModelContainer = RestaurantJournalApp.makeContainer()

    /// The user's private iCloud CloudKit container. Must match the identifier checked under
    /// Signing & Capabilities → iCloud → CloudKit in Xcode. Kept short so Xcode's Add-Container field
    /// (which truncates long ids) doesn't mangle it. Container ids are developer-only and needn't
    /// match the bundle id — only the entitlement.
    static let cloudKitContainerID = "iCloud.vfxdrummer.RestaurantJournal"

    /// Whether the journal store actually initialized **with CloudKit** (vs. silently falling back to
    /// local-only). The iCloud *account* status alone doesn't reveal this — so we surface it in
    /// Settings to avoid a green "backing up" that isn't really syncing.
    private(set) static var isCloudKitActive = false
    /// If CloudKit init failed and we fell back to local-only, a short reason (shown in Settings).
    private(set) static var cloudKitSetupError: String?

    /// Builds a two-store container:
    ///  • **Journal** — the irreplaceable user data, synced to the user's private iCloud.
    ///  • **Local**   — rebuildable Vision/logo caches, kept on-device (device-specific, and cheap to
    ///    rebuild). They're CloudKit-compatible (no unique constraints, defaulted attributes) because
    ///    SwiftData validates the whole container against CloudKit's rules.
    ///
    /// `Person`/`DetectedFace` currently live in the Journal store because they relate to `Visit` and
    /// SwiftData relationships can't cross store boundaries; a later phase moves faces on-device
    /// (see docs/cloud-sync-plan.md).
    ///
    /// If the iCloud capability/provisioning isn't in place yet, we fall back to a local-only journal
    /// so the app always launches — data stays safe on-device and begins syncing once the capability
    /// is added.
    private static func makeContainer() -> ModelContainer {
        let journalTypes: [any PersistentModel.Type] = [
            Restaurant.self, Visit.self, PhotoAsset.self, VoiceNote.self,
            Person.self, DetectedFace.self
        ]
        let localTypes: [any PersistentModel.Type] = [
            ScreenedPhoto.self, EstablishmentLogo.self, FaceScannedPhoto.self
        ]
        let journalSchema = Schema(journalTypes)
        let localSchema = Schema(localTypes)
        let fullSchema = Schema(journalTypes + localTypes)

        // On-device-only caches. Distinct store name so it lives in its own file.
        let local = ModelConfiguration("Local", schema: localSchema, cloudKitDatabase: .none)

        // Preferred: journal synced to the user's private iCloud (unless the user turned it off).
        if SyncPreference.isEnabled {
            let cloudJournal = ModelConfiguration(
                "Journal", schema: journalSchema, cloudKitDatabase: .private(cloudKitContainerID)
            )
            do {
                let container = try ModelContainer(for: fullSchema, configurations: cloudJournal, local)
                isCloudKitActive = true
                return container
            } catch {
                // Record why (for the honest "sync not active" state) and fall back to local-only.
                let ns = error as NSError
                cloudKitSetupError = (ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
                    ?? error.localizedDescription
                print("[iCloudSync] CloudKit unavailable, using local-only: \(cloudKitSetupError ?? "")")
            }
        }

        // Fallback: local-only journal (sync off, or CloudKit unavailable). Never blocks launch.
        let localJournal = ModelConfiguration("Journal", schema: journalSchema, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: fullSchema, configurations: localJournal, local) {
            return container
        }

        fatalError("Could not create ModelContainer")
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .task { Analytics.log("app_open") }
        }
        .modelContainer(sharedModelContainer)
    }
}
