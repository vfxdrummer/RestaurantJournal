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

    // Tunable weights. Quality (how much you love a place) dominates; frequency is a *bounded*
    // booster so a mundane regular can't bury a beloved rare gem.
    static let qualityWeight = 2.0
    static let frequencyWeight = 0.5
    /// Quality for a place you've visited but never rated — weak positive signal.
    static let unratedBaseline = 0.5

    /// Points for a single *rated* visit.
    static func ratingValue(_ rating: VisitRating) -> Double {
        switch rating {
        case .yay: return 3
        case .okay: return 1
        case .meh: return -2
        }
    }

    /// A restaurant's seed score. **Quality** = the average of its *rated* visits (so unrated visits
    /// don't inflate it), plus a **diminishing** frequency bonus (`log2`), so "you loved it" outranks
    /// "you happened to go a lot."
    static func score(for restaurant: Restaurant) -> Double {
        let visits = liveVisits(for: restaurant)
        guard !visits.isEmpty else { return 0 }

        let rated = visits.compactMap(\.rating)
        let quality = rated.isEmpty
            ? unratedBaseline
            : rated.map(ratingValue).reduce(0, +) / Double(rated.count)

        let frequencyBonus = log2(1 + Double(visits.count))
        return quality * qualityWeight + frequencyBonus * frequencyWeight
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
