import SwiftUI
import SwiftData

@main
struct RestaurantJournalApp: App {
    let sharedModelContainer: ModelContainer = RestaurantJournalApp.makeContainer()

    /// The user's private iCloud CloudKit container. Must match the identifier added under
    /// Signing & Capabilities → iCloud → CloudKit in Xcode.
    static let cloudKitContainerID = "iCloud.com.vfxdrummer.RestaurantJournal"

    /// Builds a two-store container:
    ///  • **Journal** — the irreplaceable user data, synced to the user's private iCloud.
    ///  • **Local**   — rebuildable Vision/logo caches, kept on-device (they use `@Attribute(.unique)`,
    ///    which CloudKit forbids).
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

        // Preferred: journal synced to the user's private iCloud.
        let cloudJournal = ModelConfiguration(
            "Journal", schema: journalSchema,
            cloudKitDatabase: .private(cloudKitContainerID)
        )
        if let container = try? ModelContainer(for: fullSchema, configurations: cloudJournal, local) {
            return container
        }

        // Fallback: local-only journal (capability not provisioned yet). Never blocks launch.
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
