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
    private static let didRemapKey = "didRemapPhotosAfterRestore"

    static func run(context: ModelContext) async {
        // Give an in-progress scan sole ownership of the context; if it's still going after the
        // wait, defer — the post-scan trigger (or next launch) will pick this up.
        guard await waitForScanIdle() else { return }
        await remapAfterRestoreIfNeeded(context: context)
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

    // MARK: - 1. One-time restore remap

    /// On the first launch of a fresh install, re-link photos whose local identifiers came from
    /// another device. No-op on the device that created the data (identifiers already resolve).
    private static func remapAfterRestoreIfNeeded(context: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: didRemapKey) else { return }
        guard !VisitDiscoveryService.isScanning else { return }

        guard let photos = try? context.fetch(FetchDescriptor<PhotoAsset>()) else { return }
        let allLocalIDs = photos.map(\.localIdentifier).filter { !$0.isEmpty }

        // Which of our stored local identifiers are missing on *this* device?
        let present = await PhotoLibraryLinker.existingLocalIdentifiers(from: allLocalIDs)
        let stale = photos.filter { !$0.localIdentifier.isEmpty && !present.contains($0.localIdentifier) }

        // Remap the stale ones that carry a cloud identifier.
        let cloudIDs = stale.compactMap(\.photoCloudIdentifier)
        var cloudToLocal: [String: String] = [:]
        if !cloudIDs.isEmpty {
            cloudToLocal = await PhotoLibraryLinker.localIdentifiers(forCloudIdentifiers: cloudIDs)
        }

        // Synchronous mutate + save burst — guard immediately before it (no `await` inside) so a scan
        // that started during the awaits above can't interleave a conflicting save.
        guard !VisitDiscoveryService.isScanning else { return }
        var remapped = 0
        for photo in stale {
            if let cloud = photo.photoCloudIdentifier, let newLocal = cloudToLocal[cloud] {
                photo.localIdentifier = newLocal
                remapped += 1
            }
        }
        if remapped > 0 { try? context.save() }
        UserDefaults.standard.set(true, forKey: didRemapKey)
    }

    // MARK: - 2. Cloud-identifier backfill

    /// Capture cloud identifiers for photos that don't have one yet, in bounded batches.
    private static func backfillCloudIdentifiers(context: ModelContext, limit: Int = 200) async {
        guard !VisitDiscoveryService.isScanning else { return }

        var descriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.photoCloudIdentifier == nil }
        )
        descriptor.fetchLimit = limit
        guard let photos = try? context.fetch(descriptor), !photos.isEmpty else { return }

        let localIDs = photos.map(\.localIdentifier).filter { !$0.isEmpty }
        let localToCloud = await PhotoLibraryLinker.cloudIdentifiers(forLocalIdentifiers: localIDs)
        guard !localToCloud.isEmpty else { return }

        // Synchronous mutate + save burst (see remap note).
        guard !VisitDiscoveryService.isScanning else { return }
        var updated = 0
        for photo in photos {
            if let cloud = localToCloud[photo.localIdentifier] {
                photo.photoCloudIdentifier = cloud
                updated += 1
            }
        }
        if updated > 0 { try? context.save() }
    }
}
