import Foundation
import SwiftData

/// Resolves a `RestaurantCandidate` to a persisted `Restaurant`, deduping by name + rough
/// coordinates so repeat visits to the same place link to one record. Shared by the scanner and
/// the manual "correct the place" flow.
@MainActor
enum RestaurantResolver {

    /// Two restaurants within this lat/lon delta (~50m) with the same name are treated as one.
    private static let coordinateEpsilon = 0.0005

    static func findOrCreate(from candidate: RestaurantCandidate, in context: ModelContext) throws -> Restaurant {
        let name = candidate.name
        let descriptor = FetchDescriptor<Restaurant>(predicate: #Predicate { $0.name == name })
        let matches = try context.fetch(descriptor)

        if let existing = matches.first(where: { restaurant in
            abs(restaurant.latitude - candidate.coordinate.latitude) < coordinateEpsilon
                && abs(restaurant.longitude - candidate.coordinate.longitude) < coordinateEpsilon
        }) {
            // Backfill fields that may not have been captured when the record was created.
            if existing.websiteHost == nil, let host = candidate.websiteHost {
                existing.websiteHost = host
            }
            if existing.categoryRawValue == nil, let category = candidate.categoryRawValue {
                existing.categoryRawValue = category
            }
            return existing
        }

        let restaurant = Restaurant(
            name: candidate.name,
            latitude: candidate.coordinate.latitude,
            longitude: candidate.coordinate.longitude,
            address: candidate.address,
            mapItemIdentifier: candidate.mapItemIdentifier,
            websiteHost: candidate.websiteHost,
            categoryRawValue: candidate.categoryRawValue
        )
        context.insert(restaurant)
        return restaurant
    }
}
