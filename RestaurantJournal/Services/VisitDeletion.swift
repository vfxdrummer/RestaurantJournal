import Foundation
import SwiftData

/// Handles the visit lifecycle around deletion. Deleting is a *soft* delete: the visit moves to
/// "Recently Deleted" (hidden but intact), so it can be restored losslessly. Only a permanent
/// delete — chosen explicitly or applied automatically after the grace period — truly removes the
/// visit and marks its photos dismissed so a rescan won't recreate it.
@MainActor
enum VisitDeletion {

    /// How long a soft-deleted visit lingers before it's purged for good.
    static let gracePeriod: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    /// Soft delete: hide the visit but keep everything (photos, notes, voice memos, faces) so it can
    /// be restored. The photos stay imported, so the scanner won't re-detect it while it's here.
    static func delete(_ visit: Visit, in context: ModelContext) {
        visit.deletedAt = Date()
        try? context.save()
    }

    /// Bring a soft-deleted visit back exactly as it was.
    static func restore(_ visit: Visit, in context: ModelContext) {
        visit.deletedAt = nil
        try? context.save()
    }

    /// Soft-delete every live visit at a place and mark the place ignored, so future scans stop
    /// creating visits there. Recoverable — the visits go to Recently Deleted, and the place can be
    /// un-ignored later. Used when a spot keeps producing false positives (e.g. next to home).
    static func deleteAllAndIgnore(_ restaurant: Restaurant, in context: ModelContext) {
        restaurant.isIgnored = true
        let now = Date()
        for visit in restaurant.visits where visit.deletedAt == nil {
            visit.deletedAt = now
        }
        try? context.save()
    }

    /// Permanently remove a visit and remember its photos as dismissed, so the next scan doesn't
    /// re-detect and recreate it. This is irreversible.
    static func deletePermanently(_ visit: Visit, in context: ModelContext) {
        // Capture the photo identifiers before the cascade delete removes them.
        let photoIDs = visit.photos.map { $0.localIdentifier }
        for id in photoIDs {
            markDismissed(id, in: context)
        }
        context.delete(visit)
        try? context.save()
    }

    /// Purge any soft-deleted visits whose grace period has elapsed. Cheap to call on launch.
    static func purgeExpired(in context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.deletedAt != nil && $0.deletedAt! < cutoff }
        )
        guard let expired = try? context.fetch(descriptor), !expired.isEmpty else { return }
        for visit in expired {
            deletePermanently(visit, in: context)
        }
    }

    private static func markDismissed(_ id: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<ScreenedPhoto>(predicate: #Predicate { $0.localIdentifier == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.dismissed = true
            existing.isDining = false
        } else {
            context.insert(ScreenedPhoto(localIdentifier: id, isDining: false, dismissed: true))
        }
    }
}
