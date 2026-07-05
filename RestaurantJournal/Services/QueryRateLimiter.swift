import Foundation

/// Lightweight client-side throttle for AI queries — a first line of defense so the app doesn't
/// spam the backend (and rack up cost) before the server-side limit ever kicks in. Timestamps are
/// persisted so the window survives app relaunches.
enum QueryRateLimiter {
    static let perMinute = 10
    static let perHour = 60

    private static let key = "aiQueryTimestamps"

    /// Returns a user-facing message if the query should be blocked, or `nil` if it's allowed.
    static func blockMessage(now: Date = Date()) -> String? {
        let stamps = recentTimestamps(now: now)
        let t = now.timeIntervalSince1970
        let inLastMinute = stamps.filter { t - $0 < 60 }.count
        if inLastMinute >= perMinute {
            return "You're asking a lot very quickly — give it a minute and try again."
        }
        if stamps.count >= perHour {
            return "You've reached this hour's limit. Please try again a bit later."
        }
        return nil
    }

    /// Record that a query was made.
    static func record(now: Date = Date()) {
        var stamps = recentTimestamps(now: now)
        stamps.append(now.timeIntervalSince1970)
        UserDefaults.standard.set(stamps, forKey: key)
    }

    /// Timestamps from the last hour (prunes anything older).
    private static func recentTimestamps(now: Date) -> [Double] {
        let cutoff = now.timeIntervalSince1970 - 3600
        let stored = (UserDefaults.standard.array(forKey: key) as? [Double]) ?? []
        return stored.filter { $0 > cutoff }
    }
}
