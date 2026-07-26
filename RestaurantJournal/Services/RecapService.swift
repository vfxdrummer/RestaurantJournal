import Foundation
import SwiftData

/// The cadence of a review — the user can look back over a whole month or a single week.
enum RecapPeriod: String, CaseIterable, Identifiable {
    case month, week
    var id: String { rawValue }
    var label: String { self == .month ? "Month" : "Week" }
    var calendarComponent: Calendar.Component { self == .month ? .month : .weekOfYear }
    /// Noun used in prose ("this month" / "this week").
    var noun: String { self == .month ? "month" : "week" }
}

/// A reflective summary of the dining you did in one period — a *celebration* of what happened
/// (visits, new discoveries, the places you love), never a streak you can break. Built on the fly
/// from the journal; stores nothing, syncs nothing.
struct Recap: Identifiable {
    var id: Date { interval.start }
    let period: RecapPeriod
    let interval: DateInterval
    /// Display title, e.g. "July 2026" or "Jul 21 – 27".
    let title: String

    let visitCount: Int
    let uniquePlaceCount: Int
    /// Places you visited for the *first time ever* during this period.
    let newDiscoveries: [Restaurant]
    /// Visits to a place you'd been to before — the north-star "you went back" signal.
    let revisitCount: Int
    let ratingCounts: [VisitRating: Int]
    /// The place you leaned into most this period (most-visited, tie-broken by ranking).
    let topPlace: Restaurant?
    /// Distinct cities visited, most-frequent first.
    let cities: [String]
    /// A few visits with a cover photo, for the header collage.
    let collage: [Visit]

    var newDiscoveryCount: Int { newDiscoveries.count }
    var isEmpty: Bool { visitCount == 0 }
}

enum RecapService {

    /// Every period (month or week) that has at least one live visit, most recent first.
    static func availableRecaps(
        _ period: RecapPeriod,
        from visits: [Visit],
        calendar: Calendar = .current,
        collageLimit: Int = 6
    ) -> [Recap] {
        let live = visits.filter { $0.deletedAt == nil }
        guard !live.isEmpty else { return [] }

        let firstVisitDates = firstVisitDates(live)

        // Bucket visits by the period interval they fall in.
        var intervals: [Date: DateInterval] = [:]
        var byStart: [Date: [Visit]] = [:]
        for visit in live {
            guard let interval = calendar.dateInterval(of: period.calendarComponent, for: visit.date) else { continue }
            intervals[interval.start] = interval
            byStart[interval.start, default: []].append(visit)
        }

        return intervals.keys.sorted(by: >).compactMap { start in
            guard let interval = intervals[start] else { return nil }
            return build(
                period: period,
                interval: interval,
                visits: byStart[start] ?? [],
                firstVisitDates: firstVisitDates,
                collageLimit: collageLimit
            )
        }
    }

    /// Earliest live-visit date per restaurant — lets us tell a first-time discovery from a revisit.
    private static func firstVisitDates(_ live: [Visit]) -> [PersistentIdentifier: Date] {
        var map: [PersistentIdentifier: Date] = [:]
        for visit in live {
            guard let restaurant = visit.restaurant else { continue }
            let id = restaurant.persistentModelID
            if let existing = map[id] {
                if visit.date < existing { map[id] = visit.date }
            } else {
                map[id] = visit.date
            }
        }
        return map
    }

    private static func build(
        period: RecapPeriod,
        interval: DateInterval,
        visits: [Visit],
        firstVisitDates: [PersistentIdentifier: Date],
        collageLimit: Int
    ) -> Recap {
        let sorted = visits.sorted { $0.date > $1.date }

        var ratingCounts: [VisitRating: Int] = [:]
        var discoveries: [Restaurant] = []
        var discovered = Set<PersistentIdentifier>()
        var revisits = 0

        var placeVisitCounts: [PersistentIdentifier: Int] = [:]
        var restaurantByID: [PersistentIdentifier: Restaurant] = [:]
        var cityCounts: [String: Int] = [:]

        for visit in sorted {
            if let rating = visit.rating { ratingCounts[rating, default: 0] += 1 }

            guard let restaurant = visit.restaurant else { continue }
            let id = restaurant.persistentModelID
            restaurantByID[id] = restaurant
            placeVisitCounts[id, default: 0] += 1

            if let city = restaurant.city, !city.isEmpty {
                cityCounts[city, default: 0] += 1
            }

            // The restaurant's earliest-ever live visit. If it equals this visit, this is the very
            // first time here → a discovery; otherwise the user is coming back → a revisit.
            let firstEver = firstVisitDates[id]
            if let firstEver, firstEver < visit.date {
                revisits += 1
            } else if discovered.insert(id).inserted {
                discoveries.append(restaurant)
            }
        }

        // Most-visited place this period; ties go to the higher-ranked favorite.
        let topID = placeVisitCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let l = restaurantByID[lhs.key].map(RestaurantRanking.effectiveScore) ?? 0
            let r = restaurantByID[rhs.key].map(RestaurantRanking.effectiveScore) ?? 0
            return l < r
        }?.key
        let topPlace = topID.flatMap { restaurantByID[$0] }

        let cities = cityCounts.sorted { $0.value > $1.value }.map(\.key)
        let collage = Array(sorted.filter { $0.coverPhoto != nil }.prefix(collageLimit))

        return Recap(
            period: period,
            interval: interval,
            title: title(for: interval, period: period),
            visitCount: sorted.count,
            uniquePlaceCount: placeVisitCounts.count,
            newDiscoveries: discoveries,
            revisitCount: revisits,
            ratingCounts: ratingCounts,
            topPlace: topPlace,
            cities: cities,
            collage: collage
        )
    }

    // MARK: - Titles

    private static func title(for interval: DateInterval, period: RecapPeriod, calendar: Calendar = .current) -> String {
        switch period {
        case .month:
            return monthFormatter.string(from: interval.start)
        case .week:
            // interval.end is exclusive — step back to the last day inside the week.
            let last = interval.end.addingTimeInterval(-1)
            let start = dayMonthFormatter.string(from: interval.start)
            let sameMonth = calendar.isDate(interval.start, equalTo: last, toGranularity: .month)
            let end = (sameMonth ? dayFormatter : dayMonthFormatter).string(from: last)
            return "\(start) – \(end)"
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f
    }()
    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
}
