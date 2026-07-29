#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only logical snapshot of the journal to a file, so the scan can be tested from zero and the
/// real journal restored afterwards. It serializes the whole model graph to JSON (+ copies voice-note
/// audio); restore wipes current data and re-inserts fresh objects, which then mirror up to CloudKit
/// as new records. Not compiled into release builds.
@MainActor
enum JournalBackupService {

    // MARK: - Locations

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var backupDir: URL { documentsURL.appendingPathComponent("JournalBackup", isDirectory: true) }
    private static var audioDir: URL { backupDir.appendingPathComponent("audio", isDirectory: true) }
    private static var jsonURL: URL { backupDir.appendingPathComponent("backup.json") }

    /// When the current backup was written, or nil if none exists.
    static func backupDate() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonURL.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    // MARK: - Backup

    /// Snapshot the whole journal to the backup file. Returns the number of visits captured.
    @discardableResult
    static func backup(in context: ModelContext) -> Int {
        let restaurants = (try? context.fetch(FetchDescriptor<Restaurant>())) ?? []
        let visits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        let photos = (try? context.fetch(FetchDescriptor<PhotoAsset>())) ?? []
        let voiceNotes = (try? context.fetch(FetchDescriptor<VoiceNote>())) ?? []
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let faces = (try? context.fetch(FetchDescriptor<DetectedFace>())) ?? []

        // Stable temp ids so relationships can be rebuilt on restore.
        var rID: [PersistentIdentifier: Int] = [:]
        for (i, r) in restaurants.enumerated() { rID[r.persistentModelID] = i }
        var vID: [PersistentIdentifier: Int] = [:]
        for (i, v) in visits.enumerated() { vID[v.persistentModelID] = i }
        var pID: [PersistentIdentifier: Int] = [:]
        for (i, p) in people.enumerated() { pID[p.persistentModelID] = i }

        let backup = Backup(
            createdAt: Date(),
            restaurants: restaurants.map { r in
                RestaurantDTO(id: rID[r.persistentModelID]!, name: r.name, latitude: r.latitude,
                              longitude: r.longitude, address: r.address, mapItemIdentifier: r.mapItemIdentifier,
                              websiteHost: r.websiteHost, categoryRawValue: r.categoryRawValue, city: r.city,
                              region: r.region, country: r.country, isIgnored: r.isIgnored,
                              rankingScore: r.rankingScore, rankingComparisons: r.rankingComparisons)
            },
            visits: visits.map { v in
                VisitDTO(id: vID[v.persistentModelID]!,
                         restaurantID: v.restaurant.flatMap { rID[$0.persistentModelID] },
                         date: v.date, userNote: v.userNote, occasion: v.occasion,
                         latitude: v.latitude, longitude: v.longitude,
                         coverPhotoLocalIdentifier: v.coverPhotoLocalIdentifier,
                         coverThumbnailData: v.coverThumbnailData, deletedAt: v.deletedAt,
                         ratingRaw: v.ratingRaw, cardTransactionID: v.cardTransactionID,
                         amount: v.amount, currencyCode: v.currencyCode)
            },
            photos: photos.map { p in
                PhotoDTO(visitID: p.visit.flatMap { vID[$0.persistentModelID] },
                         localIdentifier: p.localIdentifier, takenAt: p.takenAt,
                         photoCloudIdentifier: p.photoCloudIdentifier, latitude: p.latitude,
                         longitude: p.longitude, isVideo: p.isVideo)
            },
            voiceNotes: voiceNotes.map { n in
                VoiceNoteDTO(visitID: n.visit.flatMap { vID[$0.persistentModelID] },
                             audioFilename: n.audioFilename, transcript: n.transcript, recordedAt: n.recordedAt)
            },
            people: people.map { p in
                PersonDTO(id: pID[p.persistentModelID]!, representativeFaceData: p.representativeFaceData,
                          representativeFeaturePrintData: p.representativeFeaturePrintData, createdAt: p.createdAt)
            },
            faces: faces.map { f in
                FaceDTO(personID: f.person.flatMap { pID[$0.persistentModelID] },
                        visitID: f.visit.flatMap { vID[$0.persistentModelID] },
                        photoLocalIdentifier: f.photoLocalIdentifier, faceCropData: f.faceCropData)
            }
        )

        let fm = FileManager.default
        try? fm.removeItem(at: backupDir)   // overwrite any previous backup
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: jsonURL)
        } catch {
            print("[backup] encode failed: \(error)")
            return 0
        }

        // Copy voice-note audio into the backup (reset deletes the originals from Documents).
        for note in voiceNotes {
            let src = note.audioURL
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.copyItem(at: src, to: audioDir.appendingPathComponent(note.audioFilename))
        }

        return visits.count
    }

    // MARK: - Restore

    /// Wipe current data and rebuild the journal from the backup file. Returns visits restored.
    @discardableResult
    static func restore(in context: ModelContext) -> Int {
        guard let data = try? Data(contentsOf: jsonURL) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data) else {
            print("[restore] decode failed")
            return 0
        }

        // Clear everything first so restore is idempotent (and clears any scan test data + coverage).
        DataResetService.resetAll(in: context)

        var restaurantsByID: [Int: Restaurant] = [:]
        for dto in backup.restaurants {
            let r = Restaurant(name: dto.name, latitude: dto.latitude, longitude: dto.longitude,
                               address: dto.address, mapItemIdentifier: dto.mapItemIdentifier,
                               websiteHost: dto.websiteHost, categoryRawValue: dto.categoryRawValue,
                               city: dto.city, region: dto.region, country: dto.country)
            r.isIgnored = dto.isIgnored
            r.rankingScore = dto.rankingScore
            r.rankingComparisons = dto.rankingComparisons
            context.insert(r)
            restaurantsByID[dto.id] = r
        }

        var visitsByID: [Int: Visit] = [:]
        for dto in backup.visits {
            let v = Visit(date: dto.date, restaurant: dto.restaurantID.flatMap { restaurantsByID[$0] },
                          latitude: dto.latitude, longitude: dto.longitude)
            v.userNote = dto.userNote
            v.occasion = dto.occasion
            v.coverPhotoLocalIdentifier = dto.coverPhotoLocalIdentifier
            v.coverThumbnailData = dto.coverThumbnailData
            v.deletedAt = dto.deletedAt
            v.ratingRaw = dto.ratingRaw
            v.cardTransactionID = dto.cardTransactionID
            v.amount = dto.amount
            v.currencyCode = dto.currencyCode
            context.insert(v)
            visitsByID[dto.id] = v
        }

        for dto in backup.photos {
            let p = PhotoAsset(localIdentifier: dto.localIdentifier, takenAt: dto.takenAt,
                               latitude: dto.latitude, longitude: dto.longitude, isVideo: dto.isVideo)
            p.photoCloudIdentifier = dto.photoCloudIdentifier
            p.visit = dto.visitID.flatMap { visitsByID[$0] }
            context.insert(p)
        }

        let fm = FileManager.default
        for dto in backup.voiceNotes {
            let n = VoiceNote(audioFilename: dto.audioFilename, recordedAt: dto.recordedAt, transcript: dto.transcript)
            n.visit = dto.visitID.flatMap { visitsByID[$0] }
            context.insert(n)
            // Restore the audio file alongside the record.
            let backupAudio = audioDir.appendingPathComponent(dto.audioFilename)
            if fm.fileExists(atPath: backupAudio.path) {
                try? fm.copyItem(at: backupAudio, to: documentsURL.appendingPathComponent(dto.audioFilename))
            }
        }

        var peopleByID: [Int: Person] = [:]
        for dto in backup.people {
            let p = Person(representativeFaceData: dto.representativeFaceData,
                           representativeFeaturePrintData: dto.representativeFeaturePrintData,
                           createdAt: dto.createdAt)
            context.insert(p)
            peopleByID[dto.id] = p
        }

        for dto in backup.faces {
            let f = DetectedFace(photoLocalIdentifier: dto.photoLocalIdentifier, faceCropData: dto.faceCropData,
                                 person: dto.personID.flatMap { peopleByID[$0] },
                                 visit: dto.visitID.flatMap { visitsByID[$0] })
            context.insert(f)
        }

        try? context.save()

        // Leave the app looking like a normal, fully-scanned install so a later scan is incremental
        // (and doesn't re-sweep) — the restored PhotoAssets already dedupe new clusters anyway.
        if let bounds = PhotoClusteringService.assetDateBounds() {
            ScanCoverage(begin: bounds.newest, end: bounds.oldest, fullSweepComplete: true).save()
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasCompletedInitialScan")
        defaults.set(true, forKey: ScanCoverage.seededKey)

        return backup.visits.count
    }

    // MARK: - DTOs

    private struct Backup: Codable {
        var createdAt: Date
        var restaurants: [RestaurantDTO]
        var visits: [VisitDTO]
        var photos: [PhotoDTO]
        var voiceNotes: [VoiceNoteDTO]
        var people: [PersonDTO]
        var faces: [FaceDTO]
    }
    private struct RestaurantDTO: Codable {
        var id: Int
        var name: String, latitude: Double, longitude: Double
        var address: String?, mapItemIdentifier: String?, websiteHost: String?
        var categoryRawValue: String?, city: String?, region: String?, country: String?
        var isIgnored: Bool, rankingScore: Double?, rankingComparisons: Int
    }
    private struct VisitDTO: Codable {
        var id: Int, restaurantID: Int?
        var date: Date, userNote: String?, occasion: String?
        var latitude: Double?, longitude: Double?
        var coverPhotoLocalIdentifier: String?, coverThumbnailData: Data?
        var deletedAt: Date?, ratingRaw: String?
        var cardTransactionID: String?, amount: Double?, currencyCode: String?
    }
    private struct PhotoDTO: Codable {
        var visitID: Int?
        var localIdentifier: String, takenAt: Date, photoCloudIdentifier: String?
        var latitude: Double?, longitude: Double?, isVideo: Bool
    }
    private struct VoiceNoteDTO: Codable {
        var visitID: Int?
        var audioFilename: String, transcript: String?, recordedAt: Date
    }
    private struct PersonDTO: Codable {
        var id: Int
        var representativeFaceData: Data?, representativeFeaturePrintData: Data?, createdAt: Date
    }
    private struct FaceDTO: Codable {
        var personID: Int?, visitID: Int?
        var photoLocalIdentifier: String, faceCropData: Data?
    }
}
#endif
