import Foundation
import SwiftData
import Photos
import CoreLocation

/// A snapshot of scan progress, reported from the background engine back to the main-actor service.
struct ScanSnapshot: Sendable {
    var processed = 0
    var total = 0
    var matchProcessed = 0
    var matchTotal = 0
    var newVisitCount = 0
}

/// The result of a completed (or cancelled) scan.
struct ScanOutcome: Sendable {
    var scannedPhotoCount = 0
    var newVisitCount = 0
    var cancelled = false
    var completedFullSweep = false
    var noNewPhotos = false
}

/// Thread-safe cancel/pause flags shared between the main-actor `VisitDiscoveryService` (which the UI
/// drives) and the background `ScanEngine`.
final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _paused = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return _paused }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func setPaused(_ value: Bool) { lock.lock(); _paused = value; lock.unlock() }
}

/// Runs the entire scan — screening (Vision) and place-matching — on a **background** `ModelContext`,
/// so every `save()` (and the CloudKit mirroring it triggers on the synced store) happens off the
/// main thread. The UI's `@Query` picks up the writes via SwiftData's cross-context merging, and the
/// main thread stays free, so screening is fast and there are no periodic save-freezes. Progress is
/// reported back to the main-actor service via `report`.
@ModelActor
actor ScanEngine {
    // Shared state held as actor properties so the two concurrent loops (below) can use it without
    // capturing non-Sendable values (SwiftData models / PHAssets aren't Sendable).
    private var clusters: [PhotoCluster] = []
    private var screenCache: [String: ScreenedPhoto] = [:]
    private var dismissedIds: Set<String> = []
    private var classifierVersion = 0
    private var memCache: [String: [RestaurantCandidate]] = [:]

    private var diningQueue: [PhotoCluster] = []
    private var screeningFinished = false

    // Progress counters.
    private var processed = 0
    private var total = 0
    private var matchProcessed = 0
    private var matchTotal = 0
    private var newVisitCount = 0

    func run(
        doFull: Bool,
        control: ScanControl,
        report: @escaping @Sendable (ScanSnapshot) async -> Void
    ) async -> ScanOutcome {
        classifierVersion = RestaurantPhotoClassifier.version

        // Reads (background context).
        let since = doFull ? nil : latestPhotoDate()
        let importedIDs = loadImportedIDs()
        let assets = PhotoClusteringService.fetchAssets(since: since)
            .filter { !importedIDs.contains($0.localIdentifier) }
        guard !assets.isEmpty else {
            return ScanOutcome(completedFullSweep: doFull, noNewPhotos: true)
        }
        total = assets.count
        let scannedPhotoCount = assets.count
        clusters = PhotoClusteringService.cluster(assets)
        screenCache = loadScreenCache()
        dismissedIds = loadDismissedIDs()
        await report(snapshot())

        // Two concurrent stages that interleave on the engine's executor (off the main thread):
        // screening produces dining clusters; matching consumes them.
        async let screening: Void = screenLoop(control: control, report: report)
        async let matching: Void = matchLoop(control: control, report: report)
        _ = await screening
        _ = await matching

        try? modelContext.save()
        await report(snapshot())

        return ScanOutcome(
            scannedPhotoCount: scannedPhotoCount,
            newVisitCount: newVisitCount,
            cancelled: control.isCancelled,
            completedFullSweep: !control.isCancelled && doFull
        )
    }

    // MARK: - Producer: screening

    private func screenLoop(control: ScanControl, report: @escaping @Sendable (ScanSnapshot) async -> Void) async {
        var sinceSave = 0
        for cluster in clusters {
            await waitWhilePaused(control)
            if control.isCancelled { break }
            let base = processed

            var diningMatches = 0
            var looksLikeDining = false
            for asset in cluster.assets {
                if control.isCancelled { break }
                let id = asset.localIdentifier
                let isDining: Bool
                if dismissedIds.contains(id) {
                    isDining = false
                } else if let record = screenCache[id], record.isDining || record.screenerVersion >= classifierVersion {
                    isDining = record.isDining
                } else {
                    let result = await RestaurantPhotoClassifier.signals(for: asset).isDining
                    if let record = screenCache[id] {
                        record.isDining = result
                        record.screenerVersion = classifierVersion
                        record.screenedAt = Date()
                    } else {
                        let record = ScreenedPhoto(localIdentifier: id, isDining: result)
                        modelContext.insert(record)
                        screenCache[id] = record
                    }
                    isDining = result
                }
                processed += 1
                if isDining {
                    diningMatches += 1
                    if diningMatches >= VisitDiscoveryService.minimumDiningPhotosPerCluster {
                        looksLikeDining = true
                        break
                    }
                }
            }
            processed = base + cluster.assets.count
            if control.isCancelled { break }
            if looksLikeDining {
                diningQueue.append(cluster)
                matchTotal += 1
            }
            sinceSave += 1
            if sinceSave >= 20 {
                try? modelContext.save()
                sinceSave = 0
                await report(snapshot())
            }
        }
        try? modelContext.save()
        screeningFinished = true
        await report(snapshot())
    }

    // MARK: - Consumer: matching

    private func matchLoop(control: ScanControl, report: @escaping @Sendable (ScanSnapshot) async -> Void) async {
        var index = 0
        var sinceSave = 0
        while !control.isCancelled {
            await waitWhilePaused(control)
            if index < diningQueue.count {
                let cluster = diningQueue[index]
                index += 1
                await resolvePlace(for: cluster)
                matchProcessed += 1
                sinceSave += 1
                if sinceSave >= 5 {
                    try? modelContext.save()
                    sinceSave = 0
                    await report(snapshot())
                }
            } else if screeningFinished {
                break
            } else {
                try? await Task.sleep(nanoseconds: 80_000_000)   // wait for the producer
            }
        }
        try? modelContext.save()
        await report(snapshot())
    }

    private func resolvePlace(for cluster: PhotoCluster) async {
        let candidates = await lookupPlace(near: cluster.centroid)
        guard let best = candidates.first,
              let restaurant = try? RestaurantResolver.findOrCreate(from: best, in: modelContext)
        else { return }
        if restaurant.isIgnored { return }

        let target: Visit
        if let claimed = visitClaimingAnyPhoto(in: cluster) {
            target = claimed
        } else if let existing = mergeableVisit(for: restaurant, cluster: cluster) {
            target = existing
        } else {
            let visit = Visit(
                date: cluster.startDate,
                restaurant: restaurant,
                latitude: cluster.centroid.latitude,
                longitude: cluster.centroid.longitude
            )
            modelContext.insert(visit)
            newVisitCount += 1
            target = visit
            Analytics.log("visit_created", [
                "brand": LoyaltyDirectory.program(for: restaurant.name)?.brand ?? "Independent"
            ])
        }

        let alreadyAttached = Set(target.photos.map(\.localIdentifier))
        for asset in cluster.assets where !alreadyAttached.contains(asset.localIdentifier) {
            let photo = PhotoAsset(
                localIdentifier: asset.localIdentifier,
                takenAt: asset.creationDate ?? cluster.startDate,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isVideo: asset.mediaType == .video
            )
            photo.visit = target
            modelContext.insert(photo)
        }
        // Cloud identifiers are captured in bulk by SyncMaintenance right after the scan (recent
        // first), so matching isn't slowed by a per-visit PhotoKit call.
    }

    /// In-memory (per-scan) → on-disk cache → MapKit. Keeps repeat locations from re-hitting MapKit.
    private func lookupPlace(near coord: CLLocationCoordinate2D) async -> [RestaurantCandidate] {
        let key = RestaurantLookupService.bucketKey(for: coord)
        if let hit = memCache[key] { return hit }
        if let hit = PlaceLookupCache.read(key, in: modelContext) {
            memCache[key] = hit
            return hit
        }
        let result = await RestaurantLookupService.search(near: coord)
        memCache[key] = result
        if !result.isEmpty { PlaceLookupCache.write(key, result, in: modelContext) }
        return result
    }

    // MARK: - Helpers (background context)

    private func waitWhilePaused(_ control: ScanControl) async {
        while control.isPaused && !control.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func snapshot() -> ScanSnapshot {
        ScanSnapshot(processed: processed, total: total,
                     matchProcessed: matchProcessed, matchTotal: matchTotal,
                     newVisitCount: newVisitCount)
    }

    private func latestPhotoDate() -> Date? {
        var descriptor = FetchDescriptor<PhotoAsset>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.takenAt
    }

    private func loadImportedIDs() -> Set<String> {
        Set(((try? modelContext.fetch(FetchDescriptor<PhotoAsset>())) ?? []).map(\.localIdentifier))
    }

    private func loadScreenCache() -> [String: ScreenedPhoto] {
        let screened = (try? modelContext.fetch(FetchDescriptor<ScreenedPhoto>())) ?? []
        return Dictionary(screened.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { current, _ in current })
    }

    private func loadDismissedIDs() -> Set<String> {
        let descriptor = FetchDescriptor<ScreenedPhoto>(predicate: #Predicate { $0.dismissed })
        return Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.localIdentifier))
    }

    private func mergeableVisit(for restaurant: Restaurant, cluster: PhotoCluster) -> Visit? {
        let gapLimit = PhotoClusteringService.maxTimeGapSeconds
        return restaurant.visits.first { visit in
            guard visit.deletedAt == nil else { return false }
            let times = visit.photos.map(\.takenAt)
            let visitStart = times.min() ?? visit.date
            let visitEnd = times.max() ?? visit.date
            let gap = max(
                cluster.startDate.timeIntervalSince(visitEnd),
                visitStart.timeIntervalSince(cluster.endDate),
                0
            )
            return gap <= gapLimit
        }
    }

    private func visitClaimingAnyPhoto(in cluster: PhotoCluster) -> Visit? {
        let ids = cluster.assets.map(\.localIdentifier)
        guard !ids.isEmpty else { return nil }
        var descriptor = FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.localIdentifier) })
        descriptor.fetchLimit = 10
        guard let matches = try? modelContext.fetch(descriptor) else { return nil }
        return matches.lazy.compactMap { $0.visit }.first { $0.deletedAt == nil }
    }
}
