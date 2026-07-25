import Foundation
import SwiftData

/// One-time migration for users updating from the **pre-sync** App Store build, whose journal lived
/// in a single local `default.store`. The sync build uses a new CloudKit-backed `Journal.store`, so
/// without this their journal would look empty after the update.
///
/// It copies the *irreplaceable* data — restaurants (incl. "stop detecting"), visits (ratings, notes,
/// occasions, place assignments, Recently-Deleted state), photos, and voice notes — into the new
/// store, where CloudKit then syncs it up. Faces and the Vision/logo caches are rebuildable and are
/// skipped. Relationships survive because they're stored on the un-renamed to-one side (e.g.
/// `PhotoAsset.visit`), so the current models can read the old store via lightweight migration.
///
/// Safe to delete this whole file in a future release once the installed base has moved past the
/// first sync-enabled version — it's gated by a flag and no-ops when there's no legacy store.
@MainActor
enum LegacyStoreMigration {
    private static let doneKey = "didMigrateLegacyDefaultStore"

    static func migrateIfNeeded(into context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        // Mark done up front so a failure can't cause a retry loop (worst case: user rescans).
        defer { UserDefaults.standard.set(true, forKey: doneKey) }

        guard let legacyURL = legacyStoreURL(),
              FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        // Open the old store locally (lightweight migration to the current schema). Every entity that
        // exists in the file must be in the schema or it won't open — so include all nine models.
        let schema = Schema([
            Restaurant.self, Visit.self, PhotoAsset.self, VoiceNote.self,
            Person.self, DetectedFace.self,
            ScreenedPhoto.self, EstablishmentLogo.self, FaceScannedPhoto.self
        ])
        let config = ModelConfiguration("legacy", schema: schema, url: legacyURL, cloudKitDatabase: .none)
        guard let legacyContainer = try? ModelContainer(for: schema, configurations: config) else {
            print("[migration] couldn't open legacy store — skipping")
            return
        }
        let legacy = ModelContext(legacyContainer)

        guard let oldVisits = try? legacy.fetch(FetchDescriptor<Visit>()), !oldVisits.isEmpty else { return }

        // Recreate restaurants once and reuse, so visits at the same place share one Restaurant.
        var restaurantMap: [PersistentIdentifier: Restaurant] = [:]
        func migrated(_ old: Restaurant) -> Restaurant {
            if let existing = restaurantMap[old.persistentModelID] { return existing }
            let r = Restaurant(
                name: old.name, latitude: old.latitude, longitude: old.longitude,
                address: old.address, mapItemIdentifier: old.mapItemIdentifier,
                websiteHost: old.websiteHost, categoryRawValue: old.categoryRawValue,
                city: old.city, region: old.region, country: old.country
            )
            r.isIgnored = old.isIgnored
            context.insert(r)
            restaurantMap[old.persistentModelID] = r
            return r
        }

        for oldVisit in oldVisits {
            let visit = Visit(
                date: oldVisit.date,
                restaurant: oldVisit.restaurant.map(migrated),
                latitude: oldVisit.latitude, longitude: oldVisit.longitude
            )
            visit.userNote = oldVisit.userNote
            visit.occasion = oldVisit.occasion
            visit.coverPhotoLocalIdentifier = oldVisit.coverPhotoLocalIdentifier
            visit.deletedAt = oldVisit.deletedAt
            visit.ratingRaw = oldVisit.ratingRaw
            visit.cardTransactionID = oldVisit.cardTransactionID
            visit.amount = oldVisit.amount
            visit.currencyCode = oldVisit.currencyCode
            context.insert(visit)

            for oldPhoto in oldVisit.photos {
                let photo = PhotoAsset(
                    localIdentifier: oldPhoto.localIdentifier, takenAt: oldPhoto.takenAt,
                    latitude: oldPhoto.latitude, longitude: oldPhoto.longitude, isVideo: oldPhoto.isVideo
                )
                photo.visit = visit
                context.insert(photo)
            }
            for oldNote in oldVisit.voiceNotes {
                let note = VoiceNote(
                    audioFilename: oldNote.audioFilename, recordedAt: oldNote.recordedAt,
                    transcript: oldNote.transcript
                )
                note.visit = visit
                context.insert(note)
            }
        }

        // Ignored places that have no (remaining) visits would otherwise be missed.
        if let ignored = try? legacy.fetch(FetchDescriptor<Restaurant>(predicate: #Predicate { $0.isIgnored })) {
            for old in ignored where restaurantMap[old.persistentModelID] == nil { _ = migrated(old) }
        }

        try? context.save()
        print("[migration] migrated \(oldVisits.count) visits from legacy store")

        // Keep the old store as a backup (renamed so it won't be reopened), rather than deleting it.
        try? FileManager.default.moveItem(at: legacyURL, to: legacyURL.appendingPathExtension("migrated"))
    }

    private static func legacyStoreURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "default.store")
    }
}
