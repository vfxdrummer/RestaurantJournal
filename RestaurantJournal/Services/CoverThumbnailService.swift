import Foundation
import SwiftData
import UIKit

/// Generates a small JPEG of each visit's cover photo and stores it on `Visit.coverThumbnailData`.
/// Because that field syncs via CloudKit — and is generated from the source device's *local* photos,
/// so it works even without iCloud Photos — the journal renders a real cover image on a device that
/// doesn't have the originals (a new iPhone) instead of a wall of blank cards.
///
/// Processes *all* missing covers, most-recent first, committing in small batches so the top of the
/// journal fills in first on other devices. Self-quiesces once every visit with a photo has a cover.
@MainActor
enum CoverThumbnailService {
    /// Longest edge of the stored thumbnail. ~320px covers list rows and the detail hero crisply.
    static let maxPixel: CGFloat = 320

    static func backfill(context: ModelContext, batchSize: Int = 30) async {
        guard !VisitDiscoveryService.isScanning else { return }

        // Most-recent visits first — that's what the user sees at the top of the journal.
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.coverThumbnailData == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else { return }

        // Gather image data (the loads `await`), then apply + save each batch in a synchronous burst
        // (no `await` between the scan-guard and the save) so a scan can't interleave a conflict.
        var batch: [(visit: Visit, data: Data)] = []
        for visit in candidates {
            if VisitDiscoveryService.isScanning { return }   // bail; unsaved batch is retried later
            guard let cover = visit.coverPhoto else { continue }   // card-only visits have no cover
            let image = await PhotoThumbnailLoader.loadThumbnail(
                localIdentifier: cover.localIdentifier,
                targetSize: CGSize(width: maxPixel, height: maxPixel)
            )
            guard let data = image?.jpegData(compressionQuality: 0.7) else { continue }
            batch.append((visit, data))

            if batch.count >= batchSize {
                if VisitDiscoveryService.isScanning { return }
                for item in batch { item.visit.coverThumbnailData = item.data }
                try? context.save()
                batch.removeAll()
            }
        }
        guard !VisitDiscoveryService.isScanning, !batch.isEmpty else { return }
        for item in batch { item.visit.coverThumbnailData = item.data }
        try? context.save()
    }
}
