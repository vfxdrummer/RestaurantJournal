import Foundation

/// The committed, contiguous slice of the photo library we've already screened, tracked as two
/// pointers: `begin` (the newest screened photo's date) and `end` (the oldest). The scanned window is
/// `[end, begin]`; newer photos sit above `begin`, the un-scanned historical backlog below `end`.
///
/// The scan advances these two edges, and the *asymmetry* between them is what keeps the window
/// hole-free under interruption:
///  - `end` extends downward into never-scanned ground, so it commits **continuously**.
///  - `begin` only moves up once the new-photo pass connects all the way back to the old `begin`
///    (see `ScanEngine`); committing it early could strand a gap. So it commits **on completion**.
///
/// Rebuildable state (the `ScreenedPhoto` cache is the source of truth for what's been screened), so
/// it's a plain value persisted in UserDefaults.
struct ScanCoverage {
    var begin: Date?
    var end: Date?
    /// True once `end` has reached the oldest photo — the whole library is swept and only the cheap
    /// new-photo pass runs from then on (until a manual "Rescan all").
    var fullSweepComplete: Bool

    init(begin: Date? = nil, end: Date? = nil, fullSweepComplete: Bool = false) {
        self.begin = begin
        self.end = end
        self.fullSweepComplete = fullSweepComplete
    }

    private static let beginKey = "scanCoverageBegin"
    private static let endKey = "scanCoverageEnd"
    private static let sweepKey = "scanCoverageFullSweepComplete"
    /// Set once a real window exists (seeded on migration, or built by a completed sweep), so an
    /// install that already has a window is never retroactively re-seeded. Owned here so it's cleared
    /// together with the window on a data reset.
    static let seededKey = "scanCoverageSeeded"

    /// Forget the scanned window entirely — used by a data reset so the next scan starts from scratch
    /// (otherwise a stale window would make it think the whole library is already covered).
    static func clear() {
        let d = UserDefaults.standard
        [beginKey, endKey, sweepKey, seededKey].forEach { d.removeObject(forKey: $0) }
    }

    static func load() -> ScanCoverage {
        let d = UserDefaults.standard
        return ScanCoverage(
            begin: (d.object(forKey: beginKey) as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
            end: (d.object(forKey: endKey) as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
            fullSweepComplete: d.bool(forKey: sweepKey)
        )
    }

    func save() {
        let d = UserDefaults.standard
        if let begin { d.set(begin.timeIntervalSinceReferenceDate, forKey: Self.beginKey) }
        else { d.removeObject(forKey: Self.beginKey) }
        if let end { d.set(end.timeIntervalSinceReferenceDate, forKey: Self.endKey) }
        else { d.removeObject(forKey: Self.endKey) }
        d.set(fullSweepComplete, forKey: Self.sweepKey)
    }
}
