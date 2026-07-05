import Foundation
import SwiftData
import CoreLocation

@Model
final class Restaurant {
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String?
    var mapItemIdentifier: String?
    /// Website host (e.g. "rosas-taqueria.com") used to fetch the establishment's icon/logo.
    var websiteHost: String?
    /// `MKPointOfInterestCategory.rawValue` (e.g. "MKPOICategoryCafe"), used to pick a
    /// category-appropriate fallback symbol when no logo is available.
    var categoryRawValue: String?

    @Relationship(deleteRule: .cascade, inverse: \Visit.restaurant)
    var visits: [Visit] = []

    init(name: String, latitude: Double, longitude: Double, address: String? = nil, mapItemIdentifier: String? = nil, websiteHost: String? = nil, categoryRawValue: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.mapItemIdentifier = mapItemIdentifier
        self.websiteHost = websiteHost
        self.categoryRawValue = categoryRawValue
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Model
final class Visit {
    var date: Date
    var restaurant: Restaurant?
    var userNote: String?
    var occasion: String?
    /// The cluster centroid this visit was detected at — used to re-query nearby places when
    /// correcting a wrong restaurant match.
    var latitude: Double?
    var longitude: Double?

    @Relationship(deleteRule: .cascade, inverse: \PhotoAsset.visit)
    var photos: [PhotoAsset] = []

    @Relationship(deleteRule: .cascade, inverse: \VoiceNote.visit)
    var voiceNotes: [VoiceNote] = []

    init(date: Date, restaurant: Restaurant? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.date = date
        self.restaurant = restaurant
        self.latitude = latitude
        self.longitude = longitude
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
    var localIdentifier: String
    var takenAt: Date
    var latitude: Double?
    var longitude: Double?
    var visit: Visit?

    init(localIdentifier: String, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil) {
        self.localIdentifier = localIdentifier
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

@Model
final class VoiceNote {
    var audioFilename: String  // relative to Documents dir
    var transcript: String?
    var recordedAt: Date
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
    var screenedAt: Date

    init(localIdentifier: String, isDining: Bool, dismissed: Bool = false, screenedAt: Date = Date()) {
        self.localIdentifier = localIdentifier
        self.isDining = isDining
        self.dismissed = dismissed
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
