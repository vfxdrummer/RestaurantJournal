import Foundation
import MapKit

struct RestaurantCandidate {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String?
    let mapItemIdentifier: String?
    let websiteHost: String?
    let categoryRawValue: String?
}

enum RestaurantLookupService {
    /// Search food-related POIs near a coordinate; return best candidate + alternatives.
    static func lookup(near coordinate: CLLocationCoordinate2D) async -> [RestaurantCandidate] {
        let request = MKLocalPointsOfInterestRequest(
            center: coordinate,
            radius: 100
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket
        ])

        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return [] }

        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let sorted = response.mapItems.sorted { a, b in
            let aLoc = a.placemark.location ?? origin
            let bLoc = b.placemark.location ?? origin
            return origin.distance(from: aLoc) < origin.distance(from: bLoc)
        }

        return sorted.map { item in
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
                categoryRawValue: item.pointOfInterestCategory?.rawValue
            )
        }
    }

    private static func formatAddress(_ placemark: MKPlacemark) -> String? {
        var parts: [String] = []
        if let n = placemark.subThoroughfare { parts.append(n) }
        if let s = placemark.thoroughfare { parts.append(s) }
        if let city = placemark.locality { parts.append(city) }
        if let state = placemark.administrativeArea { parts.append(state) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
