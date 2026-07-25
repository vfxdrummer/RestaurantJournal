import Foundation
import SwiftData
import CoreLocation

/// How the user felt about a visit.
enum VisitRating: String, CaseIterable, Identifiable {
    case yay, okay, meh
    var id: String { rawValue }
    var label: String {
        switch self {
        case .yay: return "Yay!"
        case .okay: return "Okay"
        case .meh: return "Meh"
        }
    }
    var emoji: String {
        switch self {
        case .yay: return "😋"
        case .okay: return "🙂"
        case .meh: return "😐"
        }
    }
}

@Model
final class Restaurant {
    // Non-optional attributes carry defaults because this model syncs via CloudKit, which requires
    // every stored property to be optional or have a default. Initializers always overwrite them.
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var address: String?
    var mapItemIdentifier: String?
    /// Website host (e.g. "rosas-taqueria.com") used to fetch the establishment's icon/logo.
    var websiteHost: String?
    /// `MKPointOfInterestCategory.rawValue` (e.g. "MKPOICategoryCafe"), used to pick a
    /// category-appropriate fallback symbol when no logo is available.
    var categoryRawValue: String?
    /// Place hierarchy, captured for search (e.g. "where did I eat in Italy / California").
    var city: String?
    var region: String?
    var country: String?
    /// When true, scans never create visits here (e.g. a restaurant next to the user's home that
    /// keeps generating false positives). Set via "Stop detecting this place".
    var isIgnored: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Visit.restaurant)
    var visits: [Visit] = []

    init(name: String, latitude: Double, longitude: Double, address: String? = nil, mapItemIdentifier: String? = nil, websiteHost: String? = nil, categoryRawValue: String? = nil, city: String? = nil, region: String? = nil, country: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.mapItemIdentifier = mapItemIdentifier
        self.websiteHost = websiteHost
        self.categoryRawValue = categoryRawValue
        self.city = city
        self.region = region
        self.country = country
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Model
final class Visit {
    // Default required for CloudKit sync (see Restaurant); init always sets the real date.
    var date: Date = Date()
    var restaurant: Restaurant?
    var userNote: String?
    var occasion: String?
    /// The cluster centroid this visit was detected at — used to re-query nearby places when
    /// correcting a wrong restaurant match.
    var latitude: Double?
    var longitude: Double?
    /// The user-chosen cover photo (by PHAsset local identifier). Falls back to the first photo.
    var coverPhotoLocalIdentifier: String?
    /// A small (~300px) JPEG of the cover photo, synced via CloudKit so the journal still renders on
    /// a device that doesn't have the original photos (e.g. a new phone without iCloud Photos).
    /// Generated lazily; nil until produced.
    @Attribute(.externalStorage) var coverThumbnailData: Data?
    /// When set, this visit is in "Recently Deleted": hidden everywhere but fully recoverable, and
    /// permanently purged after a grace period. `nil` means the visit is live.
    var deletedAt: Date?

    /// The user's rating of this visit (raw value of `VisitRating`).
    var ratingRaw: String?

    /// The user's rating of this visit, as a typed value.
    var rating: VisitRating? {
        get { ratingRaw.flatMap(VisitRating.init) }
        set { ratingRaw = newValue?.rawValue }
    }

    /// The Plaid transaction this visit was created from or matched to — dedupes card ingestion.
    var cardTransactionID: String?
    /// The card charge amount + currency, when this visit came from (or was matched to) a card.
    var amount: Double?
    var currencyCode: String?

    /// A visit sourced only from a card charge (no photos backing it).
    var isCardOnly: Bool { cardTransactionID != nil && photos.isEmpty }

    @Relationship(deleteRule: .cascade, inverse: \PhotoAsset.visit)
    var photos: [PhotoAsset] = []

    @Relationship(deleteRule: .cascade, inverse: \VoiceNote.visit)
    var voiceNotes: [VoiceNote] = []

    @Relationship(deleteRule: .cascade, inverse: \DetectedFace.visit)
    var detectedFaces: [DetectedFace] = []

    init(date: Date, restaurant: Restaurant? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.date = date
        self.restaurant = restaurant
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The photo that represents this visit in lists — the chosen cover, or the first photo.
    var coverPhoto: PhotoAsset? {
        if let id = coverPhotoLocalIdentifier,
           let match = photos.first(where: { $0.localIdentifier == id }) {
            return match
        }
        return photos.first
    }

    /// The best available coordinate for re-querying places: the visit's own centroid, or the
    /// assigned restaurant's location as a fallback.
    var lookupCoordinate: CLLocationCoordinate2D? {
        if let latitude, let longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return restaurant?.coordinate
    }

    /// Combined searchable text for LLM queries
    var searchableDescription: String {
        var parts: [String] = []
        if let restaurant { parts.append("Restaurant: \(restaurant.name)") }
        parts.append("Date: \(date.formatted(date: .abbreviated, time: .shortened))")
        if let occasion, !occasion.isEmpty { parts.append("Occasion: \(occasion)") }
        if let userNote, !userNote.isEmpty { parts.append("Note: \(userNote)") }
        let transcripts = voiceNotes.compactMap { $0.transcript }.joined(separator: " ")
        if !transcripts.isEmpty { parts.append("Voice notes: \(transcripts)") }
        return parts.joined(separator: " | ")
    }
}

@Model
final class PhotoAsset {
    // Defaults required for CloudKit sync (see Restaurant); init always sets real values.
    var localIdentifier: String = ""
    var takenAt: Date = Date()
    /// The photo's `PHCloudIdentifier`, captured so the asset can be re-linked to the same photo on
    /// a *different* device that shares the user's iCloud Photo Library (local identifiers differ
    /// across devices; cloud identifiers are stable). Nil until captured / for non-iCloud photos.
    var photoCloudIdentifier: String?
    var latitude: Double?
    var longitude: Double?
    var isVideo: Bool = false
    var visit: Visit?

    init(localIdentifier: String, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil, isVideo: Bool = false) {
        self.localIdentifier = localIdentifier
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.isVideo = isVideo
    }
}

@Model
final class VoiceNote {
    // Defaults required for CloudKit sync (see Restaurant); init always sets real values.
    var audioFilename: String = ""  // relative to Documents dir
    var transcript: String?
    var recordedAt: Date = Date()
    var visit: Visit?

    init(audioFilename: String, recordedAt: Date, transcript: String? = nil) {
        self.audioFilename = audioFilename
        self.recordedAt = recordedAt
        self.transcript = transcript
    }

    var audioURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(audioFilename)
    }
}

/// Cache of the ML dining screen for a PHAsset, so rescans don't re-run Vision on
/// photos we've already classified (including ones that were rejected and never
/// became a Visit). Keyed by the asset's stable `localIdentifier`.
@Model
final class ScreenedPhoto {
    @Attribute(.unique) var localIdentifier: String
    var isDining: Bool
    /// Set when the user deletes a visit — the scanner then skips this photo so the visit isn't
    /// recreated on the next scan.
    var dismissed: Bool
    /// The classifier version that produced `isDining`. When the classifier improves (its version
    /// bumps), a full rescan re-evaluates stale *negatives* — positives are left alone. Defaults to
    /// 0 so any photos screened before versioning are treated as stale.
    var screenerVersion: Int = 0
    var screenedAt: Date

    init(localIdentifier: String, isDining: Bool, dismissed: Bool = false, screenerVersion: Int = RestaurantPhotoClassifier.version, screenedAt: Date = Date()) {
        self.localIdentifier = localIdentifier
        self.isDining = isDining
        self.dismissed = dismissed
        self.screenerVersion = screenerVersion
        self.screenedAt = screenedAt
    }
}

/// Persistent, disk-backed lookup of establishment logos keyed by website host, so a logo is
/// fetched from the web at most once and then survives app relaunches. `isMissing` records a
/// negative result (we looked and found nothing) so we don't keep re-hitting logo-less sites.
@Model
final class EstablishmentLogo {
    @Attribute(.unique) var host: String
    /// The icon bytes, stored outside the main store on disk when large enough.
    @Attribute(.externalStorage) var imageData: Data?
    /// The URL the icon was resolved from — lets us refresh from the same source later.
    var resolvedIconURLString: String?
    var isMissing: Bool
    /// Which logo sources were enabled when a negative result was recorded. If this no longer
    /// matches the current sources (e.g. Brandfetch was turned on), the miss is re-evaluated.
    var missSignature: String?
    var fetchedAt: Date

    init(host: String, imageData: Data? = nil, resolvedIconURLString: String? = nil, isMissing: Bool = false, missSignature: String? = nil, fetchedAt: Date = Date()) {
        self.host = host
        self.imageData = imageData
        self.resolvedIconURLString = resolvedIconURLString
        self.isMissing = isMissing
        self.missSignature = missSignature
        self.fetchedAt = fetchedAt
    }
}

/// A person you've dined with — a cluster of detected faces, identified by their face (no name).
/// Ranked in the People tab by how many visits they appear in.
@Model
final class Person {
    /// A representative face crop for the icon.
    @Attribute(.externalStorage) var representativeFaceData: Data?
    /// Archived Vision feature print of the representative face, used to cluster new faces.
    var representativeFeaturePrintData: Data?
    // Default required for CloudKit sync (see Restaurant); init always sets the real value.
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \DetectedFace.person)
    var faces: [DetectedFace] = []

    init(representativeFaceData: Data? = nil, representativeFeaturePrintData: Data? = nil, createdAt: Date = Date()) {
        self.representativeFaceData = representativeFaceData
        self.representativeFeaturePrintData = representativeFeaturePrintData
        self.createdAt = createdAt
    }

    /// The unique visits this person appears in (each place you've dined together).
    var uniqueVisits: [Visit] {
        var seen = Set<PersistentIdentifier>()
        var result: [Visit] = []
        for face in faces {
            if let visit = face.visit, visit.deletedAt == nil,
               seen.insert(visit.persistentModelID).inserted {
                result.append(visit)
            }
        }
        return result
    }

    /// How many times you've dined with this person (the ranking metric).
    var diningCount: Int { uniqueVisits.count }
    /// Total photos this person appears in (the tiebreaker).
    var photoCount: Int { faces.count }
}

/// A single face found in one photo, linked to the clustered `Person` and the `Visit` it belongs to.
@Model
final class DetectedFace {
    // Default required for CloudKit sync (see Restaurant); init always sets the real value.
    var photoLocalIdentifier: String = ""
    @Attribute(.externalStorage) var faceCropData: Data?
    var person: Person?
    var visit: Visit?

    init(photoLocalIdentifier: String, faceCropData: Data? = nil, person: Person? = nil, visit: Visit? = nil) {
        self.photoLocalIdentifier = photoLocalIdentifier
        self.faceCropData = faceCropData
        self.person = person
        self.visit = visit
    }
}

/// Marks a photo as already scanned for faces, so a rescan skips it (even if it had no faces).
@Model
final class FaceScannedPhoto {
    @Attribute(.unique) var localIdentifier: String

    init(localIdentifier: String) {
        self.localIdentifier = localIdentifier
    }
}
