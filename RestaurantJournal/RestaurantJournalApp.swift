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
    /// Which CloudKit layout ended up active ("two-store" / "single-store"), for diagnostics.
    private(set) static var cloudKitStoreMode: String?
    /// If CloudKit init failed and we fell back to local-only, the reason(s) (for diagnostics).
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

        // Try CloudKit layouts in order; use the first that loads. This also diagnoses whether the
        // *multi-store* mechanics are the blocker (if single-store loads when two-store didn't).
        if SyncPreference.isEnabled {
            // Attempt 1 — two-store: journal → CloudKit, caches local (ideal; caches never sync).
            do {
                let cloudJournal = ModelConfiguration(
                    "Journal", schema: journalSchema, cloudKitDatabase: .private(cloudKitContainerID)
                )
                let container = try ModelContainer(for: fullSchema, configurations: cloudJournal, local)
                isCloudKitActive = true
                cloudKitStoreMode = "two-store"
                print("[iCloudSync] CloudKit active: two-store")
                return container
            } catch {
                recordSetupError("two-store", error)
            }

            // Attempt 2 — single store, everything in CloudKit. All models are CloudKit-compatible, so
            // this isolates whether the multi-store setup is what fails. (If this is what ends up used,
            // the device-specific caches sync too — we'd move them back local once sync is confirmed.)
            do {
                let unified = ModelConfiguration(
                    "Unified", schema: fullSchema, cloudKitDatabase: .private(cloudKitContainerID)
                )
                let container = try ModelContainer(for: fullSchema, configurations: unified)
                isCloudKitActive = true
                cloudKitStoreMode = "single-store"
                print("[iCloudSync] CloudKit active: single-store (two-store failed)")
                return container
            } catch {
                recordSetupError("single-store", error)
            }
        }

        // Fallback: local-only journal (sync off, or CloudKit unavailable). Never blocks launch.
        let localJournal = ModelConfiguration("Journal", schema: journalSchema, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: fullSchema, configurations: localJournal, local) {
            return container
        }

        fatalError("Could not create ModelContainer")
    }

    /// Append a formatted CloudKit init failure to `cloudKitSetupError` and log it (SwiftDataError is
    /// generic, so we pull whatever detail we can from the bridged NSError).
    private static func recordSetupError(_ label: String, _ error: Error) {
        let ns = error as NSError
        var detail = "[\(label)] \(String(reflecting: error))"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += " ‖ underlying: \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            detail += " ‖ reason: \(reason)"
        }
        cloudKitSetupError = [cloudKitSetupError, detail].compactMap { $0 }.joined(separator: "  •  ")
        print("[iCloudSync] \(label) FAILED: \(detail)")
        print("[iCloudSync]   full userInfo: \(ns.userInfo)")
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .task { Analytics.log("app_open") }
        }
        .modelContainer(sharedModelContainer)
    }
}
