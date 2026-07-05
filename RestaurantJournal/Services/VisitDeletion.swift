import Foundation
import SwiftData

/// Deletes a visit and remembers its photos as dismissed, so the next scan doesn't re-detect and
/// recreate the same visit.
@MainActor
enum VisitDeletion {

    static func delete(_ visit: Visit, in context: ModelContext) {
        // Capture the photo identifiers before the cascade delete removes them.
        let photoIDs = visit.photos.map { $0.localIdentifier }
        for id in photoIDs {
            markDismissed(id, in: context)
        }
        context.delete(visit)
        try? context.save()
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
