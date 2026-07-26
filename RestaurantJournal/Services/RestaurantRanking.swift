import Foundation

/// Ranks the user's restaurants for the "Top 10" — Phase 1: a *derived* score, computed on the fly
/// from signal we already have (ratings + how often you've been), so it needs no stored field and no
/// CloudKit schema change. A place you rate 😋 repeatedly and keep going back to rises to the top.
///
/// The score is a simple **sum** of each live visit's rating value, which folds both signals into one
/// number: loving a place lifts it, *and* going back again and again lifts it (more visits = more
/// points). Meh visits pull it down. Phase 2 will layer explicit "which was better?" comparisons on
/// top of this seed.
enum RestaurantRanking {

    /// Points a single visit contributes, by rating. Unrated visits count for a little (you went, so
    /// there's mild positive signal); Meh actively pulls a place down.
    static func value(for rating: VisitRating?) -> Double {
        switch rating {
        case .yay: return 3
        case .okay: return 1
        case .meh: return -2
        case nil: return 0.5
        }
    }

    /// A restaurant's seed score: the sum of its live visits' rating values.
    static func score(for restaurant: Restaurant) -> Double {
        restaurant.visits.reduce(0) { total, visit in
            visit.deletedAt == nil ? total + value(for: visit.rating) : total
        }
    }

    /// The user's live visits at a restaurant (used for the row subtitle and to require ≥1 visit).
    static func liveVisits(for restaurant: Restaurant) -> [Visit] {
        restaurant.visits.filter { $0.deletedAt == nil }
    }

    /// Top-ranked restaurants (highest score first), excluding ignored places and any with no live
    /// visits or a non-positive score (a place you only Meh'd shouldn't make your Top 10).
    static func top(_ restaurants: [Restaurant], limit: Int = 10) -> [Restaurant] {
        restaurants
            .filter { !$0.isIgnored && !liveVisits(for: $0).isEmpty }
            .map { (restaurant: $0, score: score(for: $0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.restaurant)
    }
}
