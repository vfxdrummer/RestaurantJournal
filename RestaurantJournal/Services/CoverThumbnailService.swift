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

    /// Fill in missing cover thumbnails, up to `limit` per call.
    static func backfill(context: ModelContext, limit: Int = 40) async {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.coverThumbnailData == nil && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = limit * 3  // over-fetch: some candidates are card-only (no photo)
        guard let candidates = try? context.fetch(descriptor) else { return }

        var written = 0
        for visit in candidates {
            if written >= limit { break }
            guard let cover = visit.coverPhoto else { continue }  // card-only visits have no cover
            let image = await PhotoThumbnailLoader.loadThumbnail(
                localIdentifier: cover.localIdentifier,
                targetSize: CGSize(width: maxPixel, height: maxPixel)
            )
            guard let data = image?.jpegData(compressionQuality: 0.7) else { continue }
            visit.coverThumbnailData = data
            written += 1
        }
        if written > 0 { try? context.save() }
    }
}
