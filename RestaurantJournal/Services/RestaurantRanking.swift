import Foundation
import SwiftData

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

    // MARK: - Comparison game (ELO on top of the seed)

    private static let seedEloBase = 1500.0
    private static let seedEloWeight = 40.0   // maps the ~0–8 seed onto the ELO scale
    private static let eloK = 32.0

    /// The derived seed expressed on the ELO scale, so compared and never-compared places sort on one
    /// consistent scale.
    static func seedElo(for restaurant: Restaurant) -> Double {
        seedEloBase + score(for: restaurant) * seedEloWeight
    }

    /// The score the Top 10 sorts by: the refined ELO once the user has compared this place, else the
    /// seed (mapped onto the ELO scale).
    static func effectiveScore(for restaurant: Restaurant) -> Double {
        restaurant.rankingScore ?? seedElo(for: restaurant)
    }

    /// Record one "A was better than B" comparison — standard ELO update, materializing each place's
    /// score from its seed on first comparison.
    static func recordComparison(winner: Restaurant, loser: Restaurant, in context: ModelContext) {
        let ra = effectiveScore(for: winner)
        let rb = effectiveScore(for: loser)
        let expectedWin = 1 / (1 + pow(10, (rb - ra) / 400))
        winner.rankingScore = ra + eloK * (1 - expectedWin)
        loser.rankingScore = rb - eloK * (1 - expectedWin)
        winner.rankingComparisons += 1
        loser.rankingComparisons += 1
        try? context.save()
    }

    /// Restaurants a user could rank: has a live visit, not ignored, and either a positive seed
    /// (a favorite) or an explicit comparison score.
    static func eligible(_ restaurants: [Restaurant]) -> [Restaurant] {
        restaurants.filter { r in
            !r.isIgnored
                && !liveVisits(for: r).isEmpty
                && (r.rankingScore != nil || score(for: r) > 0)
        }
    }

    /// Top-ranked restaurants (highest effective score first).
    static func top(_ restaurants: [Restaurant], limit: Int = 10) -> [Restaurant] {
        eligible(restaurants)
            .sorted { effectiveScore(for: $0) > effectiveScore(for: $1) }
            .prefix(limit)
            .map { $0 }
    }
}
