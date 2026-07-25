import Foundation
import SwiftData

/// Background upkeep that makes iCloud restore resilient across devices. Run at launch and after each
/// scan:
///   1. **Restore remap** (once per install) — after a journal syncs down to a *new* device, each
///      `PhotoAsset.localIdentifier` points at the *old* device's library. Re-link them to this
///      device's photos via the stable cloud identifier so full-res photos reappear.
///   2. **Cloud-id backfill** — capture each photo's `PHCloudIdentifier` so a *future* device can
///      remap. Incremental; self-quiesces.
///   3. **Cover-thumbnail backfill** — generate the synced fallback image per visit.
///
/// It shares the main model context with the scanner, so it **never runs while a scan is active**:
/// it waits for the scan to finish first, and each pass re-checks right before mutating (with no
/// `await` between the check and the save) so a scan can't interleave a conflicting write.
@MainActor
enum SyncMaintenance {
    static func run(context: ModelContext) async {
        // Give an in-progress scan sole ownership of the context; if it's still going after the
        // wait, defer — the post-scan trigger (or next import) will pick this up.
        guard await waitForScanIdle() else { return }
        await remapRestoredPhotos(context: context)
        await backfillCloudIdentifiers(context: context)
        await CoverThumbnailService.backfill(context: context)
    }

    /// Wait up to ~30s for any active scan to finish. Returns false if one is still running.
    private static func waitForScanIdle(timeoutTicks: Int = 300) async -> Bool {
        var ticks = 0
        while VisitDiscoveryService.isScanning {
            if ticks >= timeoutTicks { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            ticks += 1
        }
        return true
    }

    // MARK: - 1. Restore remap

    /// Re-link photos whose local identifiers came from another device, using the stable cloud
    /// identifier. Runs at launch and after each CloudKit import, so a journal that arrives on a
    /// fresh device gets its photos re-linked as the data lands. Self-quiescing: once a photo's
    /// identifier resolves on this device it's no longer "stale", so there's nothing left to do (and
    /// it's a no-op on the device that created the data).
    private static func remapRestoredPhotos(context: ModelContext) async {
        guard !VisitDiscoveryService.isScanning else { return }

        guard let photos = try? context.fetch(FetchDescriptor<PhotoAsset>()), !photos.isEmpty else { return }
        let allLocalIDs = photos.map(\.localIdentifier).filter { !$0.isEmpty }

        // Which of our stored local identifiers are missing on *this* device?
        let present = await PhotoLibraryLinker.existingLocalIdentifiers(from: allLocalIDs)
        let stale = photos.filter { !$0.localIdentifier.isEmpty && !present.contains($0.localIdentifier) }
        guard !stale.isEmpty else { return }

        // Re-link most-recent photos first — that's what the user sees at the top of the journal —
        // and commit each batch so those tiles resolve before the older ones finish.
        let staleByRecency = stale.sorted { $0.takenAt > $1.takenAt }
        let batchSize = 100
        for start in stride(from: 0, to: staleByRecency.count, by: batchSize) {
            guard !VisitDiscoveryService.isScanning else { return }
            let batch = Array(staleByRecency[start ..< min(start + batchSize, staleByRecency.count)])
            let cloudIDs = batch.compactMap(\.photoCloudIdentifier)
            guard !cloudIDs.isEmpty else { continue }
            let cloudToLocal = await PhotoLibraryLinker.localIdentifiers(forCloudIdentifiers: cloudIDs)

            // Synchronous mutate + save burst — guard immediately before it (no `await` inside) so a
            // scan that started during the await above can't interleave a conflicting save.
            guard !VisitDiscoveryService.isScanning else { return }
            var remapped = 0
            for photo in batch {
                if let cloud = photo.photoCloudIdentifier, let newLocal = cloudToLocal[cloud] {
                    photo.localIdentifier = newLocal
                    remapped += 1
                }
            }
            if remapped > 0 { try? context.save() }
        }
    }

    // MARK: - 2. Cloud-identifier backfill

    /// Capture cloud identifiers for photos that don't have one yet — the key to re-linking on other
    /// devices. Processes *all* of them (recent first) in batches, since it's a cheap PhotoKit lookup
    /// and the faster these propagate, the faster a fresh device can re-link its photos. No-op when
    /// iCloud Photos is off (the photos then have no cloud identifiers).
    private static func backfillCloudIdentifiers(context: ModelContext) async {
        guard !VisitDiscoveryService.isScanning else { return }

        let descriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.photoCloudIdentifier == nil },
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        guard let photos = try? context.fetch(descriptor), !photos.isEmpty else { return }

        let batchSize = 300
        for start in stride(from: 0, to: photos.count, by: batchSize) {
            guard !VisitDiscoveryService.isScanning else { return }
            let batch = Array(photos[start ..< min(start + batchSize, photos.count)])
            let localIDs = batch.map(\.localIdentifier).filter { !$0.isEmpty }
            let localToCloud = await PhotoLibraryLinker.cloudIdentifiers(forLocalIdentifiers: localIDs)
            guard !localToCloud.isEmpty else { continue }

            // Synchronous mutate + save burst (see remap note).
            guard !VisitDiscoveryService.isScanning else { return }
            var updated = 0
            for photo in batch {
                if let cloud = localToCloud[photo.localIdentifier] {
                    photo.photoCloudIdentifier = cloud
                    updated += 1
                }
            }
            if updated > 0 { try? context.save() }
        }
    }
}
