import Foundation
import SwiftData
import UIKit

/// Generates a small JPEG of each visit's cover photo and stores it on `Visit.coverThumbnailData`.
/// Because that field syncs via CloudKit, the journal still renders a real image on a device that
/// doesn't have the original photos (e.g. a new iPhone without iCloud Photos) — instead of a wall of
/// blank cards. Runs in bounded batches so it never blocks the UI; self-quiesces once every visit
/// with photos has a thumbnail.
@MainActor
enum CoverThumbnailService {
    /// Longest edge of the stored thumbnail. ~320px covers list rows and the detail hero crisply.
    static let maxPixel: CGFloat = 320

    /// Fill in missing cover thumbnails, up to `limit` per call. Never runs concurrently with a scan:
    /// image data is gathered without touching the context, then applied + saved in one synchronous
    /// burst (no `await` inside) so a scan can't interleave a conflicting write.
    static func backfill(context: ModelContext, limit: Int = 40) async {
        guard !VisitDiscoveryService.isScanning else { return }

        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.coverThumbnailData == nil && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = limit * 3  // over-fetch: some candidates are card-only (no photo)
        guard let candidates = try? context.fetch(descriptor) else { return }

        // Gather image data first, mutating nothing (the loads below `await`).
        var results: [(visit: Visit, data: Data)] = []
        for visit in candidates {
            if results.count >= limit { break }
            guard let cover = visit.coverPhoto else { continue }  // card-only visits have no cover
            guard !VisitDiscoveryService.isScanning else { return }  // a scan started — bail, retry later
            let image = await PhotoThumbnailLoader.loadThumbnail(
                localIdentifier: cover.localIdentifier,
                targetSize: CGSize(width: maxPixel, height: maxPixel)
            )
            guard let data = image?.jpegData(compressionQuality: 0.7) else { continue }
            results.append((visit, data))
        }

        // Atomic apply + save.
        guard !VisitDiscoveryService.isScanning, !results.isEmpty else { return }
        for item in results { item.visit.coverThumbnailData = item.data }
        try? context.save()
    }
}
