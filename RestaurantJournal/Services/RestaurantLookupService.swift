import Foundation
import MapKit

struct RestaurantCandidate: Sendable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String?
    let mapItemIdentifier: String?
    let websiteHost: String?
    let categoryRawValue: String?
    let city: String?
    let region: String?
    let country: String?
}

/// Serializes MapKit spatial lookups so a scan stays under Apple's ~50-requests/60s throttle, and
/// caches results by ~110m location bucket so the many clusters at one restaurant reuse a single
/// request. Observable so the UI can show when matching is paused waiting on the throttle.
@MainActor
@Observable
final class GeoLookupCoordinator {
    static let shared = GeoLookupCoordinator()

    /// True while place matching is paused waiting for MapKit's rate-limit window to free up.
    private(set) var isThrottled = false

    @ObservationIgnored private var cache: [String: [RestaurantCandidate]] = [:]
    @ObservationIgnored private var timestamps: [Date] = []
    @ObservationIgnored private let maxRequests = 45           // safely under Apple's 50
    @ObservationIgnored private let window: TimeInterval = 60

    func cached(_ key: String) -> [RestaurantCandidate]? { cache[key] }
    func store(_ key: String, _ value: [RestaurantCandidate]) { cache[key] = value }

    /// Block until another spatial request can be made without exceeding the rolling window.
    func reserveSlot() async {
        while true {
            let now = Date()
            timestamps.removeAll { now.timeIntervalSince($0) >= window }
            if timestamps.count < maxRequests {
                timestamps.append(now)
                isThrottled = false
                return
            }
            if let oldest = timestamps.first {
                isThrottled = true
                let wait = window - now.timeIntervalSince(oldest) + 0.1
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.1) * 1_000_000_000))
            } else {
                isThrottled = false
                timestamps.append(now)
                return
            }
        }
    }
}

enum RestaurantLookupService {
    /// Search food-related POIs near a coordinate; return best candidate + alternatives. Cached by
    /// location, rate-limited, and retried on throttling so a big scan never silently drops matches.
    static func lookup(near coordinate: CLLocationCoordinate2D) async -> [RestaurantCandidate] {
        let key = cacheKey(for: coordinate)
        if let cached = await GeoLookupCoordinator.shared.cached(key) {
            return cached
        }

        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 100)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket
        ])
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        for attempt in 0..<3 {
            await GeoLookupCoordinator.shared.reserveSlot()
            do {
                let response = try await MKLocalSearch(request: request).start()
                let sorted = response.mapItems.sorted { a, b in
                    let aLoc = a.placemark.location ?? origin
                    let bLoc = b.placemark.location ?? origin
                    return origin.distance(from: aLoc) < origin.distance(from: bLoc)
                }
                let candidates = sorted.map(candidate(from:))
                await GeoLookupCoordinator.shared.store(key, candidates)
                return candidates
            } catch {
                // On a throttle error, wait for the window to reset and retry rather than dropping
                // the match; on any other error (or once out of retries), give up quietly.
                if let reset = throttleResetSeconds(from: error), attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64((reset + 0.5) * 1_000_000_000))
                    continue
                }
                return []
            }
        }
        return []
    }

    /// ~110m buckets (3 decimal places) so clusters at the same place share one lookup.
    private static func cacheKey(for c: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", c.latitude, c.longitude)
    }

    /// Seconds until MapKit's throttle window resets, if `error` is a throttle; nil otherwise.
    private static func throttleResetSeconds(from error: Error) -> Double? {
        let ns = error as NSError
        guard ns.domain == "GEOErrorDomain" else { return nil }
        if let t = ns.userInfo["timeUntilReset"] as? Double { return t }
        if let t = ns.userInfo["timeUntilReset"] as? Int { return Double(t) }
        if let details = ns.userInfo["details"] as? [[String: Any]],
           let t = details.first?["timeUntilReset"] as? Double { return t }
        return 20   // sensible default within the 60s window
    }

    /// Build a `RestaurantCandidate` from a map item — shared by the nearby search and the
    /// address-autocomplete flow.
    static func candidate(from item: MKMapItem) -> RestaurantCandidate {
        // MKMapItem.identifier is iOS 18+; keep the iOS 17 deployment target working.
        let mapItemIdentifier: String?
        if #available(iOS 18.0, *) {
            mapItemIdentifier = item.identifier?.rawValue
        } else {
            mapItemIdentifier = nil
        }
        return RestaurantCandidate(
            name: item.name ?? "Unknown",
            coordinate: item.placemark.coordinate,
            address: formatAddress(item.placemark),
            mapItemIdentifier: mapItemIdentifier,
            websiteHost: item.url?.host(),
            categoryRawValue: item.pointOfInterestCategory?.rawValue,
            city: item.placemark.locality,
            region: item.placemark.administrativeArea,
            country: item.placemark.country
        )
    }

    private static func formatAddress(_ placemark: MKPlacemark) -> String? {
        var parts: [String] = []
        if let n = placemark.subThoroughfare { parts.append(n) }
        if let s = placemark.thoroughfare { parts.append(s) }
        if let city = placemark.locality { parts.append(city) }
        if let state = placemark.administrativeArea { parts.append(state) }
        if let country = placemark.country { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
