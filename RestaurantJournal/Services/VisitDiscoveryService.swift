import Foundation
import Photos
import SwiftData
import CoreLocation
import Observation

/// Scans the Photos library, clusters geotagged photos, gates each cluster on ML dining evidence,
/// and inserts detected Visits. Observable so the UI can show progress; supports pause/resume.
///
/// "Resume from where it left off" is provided by the per-photo `ScreenedPhoto` cache and the
/// incremental per-cluster save: a paused, cancelled, or killed scan is re-run cheaply because
/// already-classified photos and already-created visits are skipped.
@MainActor
@Observable
final class VisitDiscoveryService {

    enum Phase: Equatable {
        case idle, scanning, paused, finished
    }

    /// How many dining-positive photos a cluster needs before it's accepted as a restaurant
    /// visit. `1` catches quick single-dish meals; raise it to cut false positives further.
    static let minimumDiningPhotosPerCluster = 1

    // MARK: - Observable progress

    private(set) var phase: Phase = .idle
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var newVisitCount = 0
    private(set) var errorMessage: String?
    private(set) var summary: String?
    /// Second, concurrent stage: places matched vs. dining clusters found so far. The denominator
    /// grows as screening discovers more, so this bar is intentionally non-linear.
    private(set) var matchProcessed = 0
    private(set) var matchTotal = 0

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    var matchProgress: Double { matchTotal > 0 ? Double(matchProcessed) / Double(matchTotal) : 0 }
    var isBusy: Bool { phase == .scanning || phase == .paused }

    // Producer/consumer state for the concurrent scan (not observed). Held on the main actor so the
    // two scan tasks can share it without Sendable concerns (SwiftData models aren't Sendable).
    @ObservationIgnored private var diningQueue: [PhotoCluster] = []
    @ObservationIgnored private var screeningFinished = false
    @ObservationIgnored private var screenCache: [String: ScreenedPhoto] = [:]

    /// True while *any* scan is running. Read by background maintenance (`SyncMaintenance`) so it
    /// never mutates the shared model context at the same time as a scan — concurrent saves can throw
    /// and cut a scan short. Set only inside `scan(in:)`.
    @MainActor private(set) static var isScanning = false

    // MARK: - Pause state (not observed)

    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        guard phase == .scanning else { return }
        isPaused = true
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        isPaused = false
        phase = .scanning
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Stop the scan early. Visits already found are kept (they're saved per cluster); the loop
    /// observes the flag and exits cleanly. Works from either scanning or paused.
    func cancel() {
        guard phase == .scanning || phase == .paused else { return }
        isCancelled = true
        // If paused, wake the suspended loop so it can observe the cancellation and finish.
        if isPaused {
            isPaused = false
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        phase = .scanning
    }

    private func waitWhilePaused() async {
        if isPaused {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pauseWaiters.append(continuation)
            }
        }
    }

    // MARK: - Scan

    func scan(in context: ModelContext, fullRescan: Bool = false) async {
        guard !isBusy else { return }
        Self.isScanning = true
        defer { Self.isScanning = false }

        phase = .scanning
        processed = 0
        total = 0
        matchProcessed = 0
        matchTotal = 0
        newVisitCount = 0
        errorMessage = nil
        summary = nil
        diningQueue = []
        screeningFinished = false
        isCancelled = false
        isPaused = false

        // 1. Photo library authorization
        let status = await requestPhotoAuth()
        guard status == .authorized || status == .limited else {
            errorMessage = "Photo library access is required to discover restaurant visits."
            phase = .finished
            return
        }

        // The everyday Scan button is ALWAYS incremental: it resumes from the last imported photo,
        // so it's fast and never re-scans the whole camera roll. A full re-screen of the library
        // only happens when the user explicitly chooses "Rescan all" from the overflow menu.
        let doFull = fullRescan
        var scannedPhotoCount = 0  // phase 1 count for the summary (`total` is reused by phase 2)

        do {
            // Incremental scans look only at photos newer than the last import (fast); a full sweep
            // checks the whole library. Either way we skip photos already imported by identifier —
            // so nothing duplicates, and new photos are never missed because of an odd/future date.
            let since = doFull ? nil : try latestPhotoDate(in: context)
            let importedIDs = try loadImportedIDs(in: context)

            // 3. Fetch + 4. cluster.
            let assets = PhotoClusteringService.fetchAssets(since: since)
                .filter { !importedIDs.contains($0.localIdentifier) }
            guard !assets.isEmpty else {
                summary = "No new photos to import."
                if doFull { lastNegativeRescanVersion = RestaurantPhotoClassifier.version }
                Analytics.log("scan_completed", ["photos_scanned": 0, "visits_added": 0, "full_rescan": doFull])
                phase = .finished
                return
            }
            total = assets.count
            scannedPhotoCount = assets.count
            let clusters = PhotoClusteringService.cluster(assets)

            screenCache = try loadScreenCache(in: context)
            let dismissedIds = try loadDismissedIDs(in: context)
            let currentVersion = RestaurantPhotoClassifier.version

            // Two concurrent stages that interleave on the main actor, so place-matching happens
            // *while* screening continues — visits appear right away instead of after the whole
            // library, and each has its own progress bar:
            //   • Producer (screening): Vision-screens clusters, queues the dining ones. CPU-bound,
            //     never waits on MapKit — the photo bar flies through the library.
            //   • Consumer (matching): resolves a place + creates a visit per queued cluster. This is
            //     the rate-limited step; throttling paces it without freezing screening.
            let screening = Task { @MainActor in
                for cluster in clusters {
                    await self.waitWhilePaused()
                    if self.isCancelled { break }
                    let clusterBase = self.processed

                    var diningMatches = 0
                    var looksLikeDining = false
                    for asset in cluster.assets {
                        if self.isCancelled { break }
                        let id = asset.localIdentifier
                        let isDining: Bool
                        if dismissedIds.contains(id) {
                            // The user deleted a visit containing this photo — never resurrect it.
                            isDining = false
                        } else if let record = self.screenCache[id], record.isDining || record.screenerVersion >= currentVersion {
                            // Trust positives always; trust a negative only if the current classifier
                            // produced it. A stale negative falls through to be re-screened below.
                            isDining = record.isDining
                        } else {
                            let result = await RestaurantPhotoClassifier.signals(for: asset).isDining
                            if let record = self.screenCache[id] {
                                record.isDining = result
                                record.screenerVersion = currentVersion
                                record.screenedAt = Date()
                            } else {
                                let record = ScreenedPhoto(localIdentifier: id, isDining: result)
                                context.insert(record)
                                self.screenCache[id] = record
                            }
                            isDining = result
                        }
                        self.processed += 1
                        if isDining {
                            diningMatches += 1
                            if diningMatches >= Self.minimumDiningPhotosPerCluster {
                                looksLikeDining = true
                                break
                            }
                        }
                    }
                    // Count photos skipped by the early break so progress still reaches 100%.
                    self.processed = clusterBase + cluster.assets.count
                    if self.isCancelled { break }
                    if looksLikeDining {
                        self.diningQueue.append(cluster)
                        self.matchTotal += 1
                    }
                    try? context.save()
                }
                self.screeningFinished = true
            }

            let matching = Task { @MainActor in
                var index = 0
                while !self.isCancelled {
                    await self.waitWhilePaused()
                    if index < self.diningQueue.count {
                        let cluster = self.diningQueue[index]
                        index += 1
                        await self.resolvePlace(for: cluster, in: context)
                        self.matchProcessed += 1
                        try? context.save()
                    } else if self.screeningFinished {
                        break   // no more coming
                    } else {
                        try? await Task.sleep(nanoseconds: 80_000_000)   // wait for the producer
                    }
                }
            }

            await screening.value
            await matching.value
            screenCache = [:]   // free the cached model references
        } catch {
            errorMessage = error.localizedDescription
        }

        if errorMessage == nil {
            if isCancelled {
                // Stopped early — keep what we found, but don't mark the version swept (it didn't
                // finish), so a later full rescan still covers the rest.
                summary = "Scan stopped · added \(newVisitCount) visit\(newVisitCount == 1 ? "" : "s") so far."
            } else {
                // The full sweep completed — mark negatives up to date for this classifier version
                // so it doesn't repeat until the next improvement.
                if doFull { lastNegativeRescanVersion = RestaurantPhotoClassifier.version }
                if summary == nil {
                    summary = "Scanned \(scannedPhotoCount) new photo\(scannedPhotoCount == 1 ? "" : "s") · added \(newVisitCount) visit\(newVisitCount == 1 ? "" : "s")."
                }
            }
        }
        Analytics.log("scan_completed", [
            "photos_scanned": scannedPhotoCount,
            "visits_added": newVisitCount,
            "cancelled": isCancelled,
            "full_rescan": doFull,
        ])
        isCancelled = false
        phase = .finished
    }

    // MARK: - Helpers

    /// Resolve a place for one dining cluster and create/attach its visit — the rate-limited
    /// consumer step of the concurrent scan.
    private func resolvePlace(for cluster: PhotoCluster, in context: ModelContext) async {
        let candidates = await RestaurantLookupService.lookup(near: cluster.centroid)
        guard let best = candidates.first,
              let restaurant = try? RestaurantResolver.findOrCreate(from: best, in: context)
        else { return }

        // The user marked this place "don't detect" (e.g. it's next to their home).
        if restaurant.isIgnored { return }

        // If the same meal was split across scans (same place, minutes apart), fold the new photos
        // into that recent visit instead of creating a duplicate.
        let target: Visit
        if let claimed = visitClaimingAnyPhoto(in: cluster, context: context) {
            // One of these photos already belongs to a visit — e.g. restored from iCloud and we're
            // rescanning. Reuse it; never duplicate.
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
            context.insert(visit)
            newVisitCount += 1
            target = visit
            // Brand-only (chains) — local restaurants bucket as "Independent" so we never send
            // specific dining-place names off the device.
            Analytics.log("visit_created", [
                "brand": LoyaltyDirectory.program(for: restaurant.name)?.brand ?? "Independent"
            ])
        }

        // Don't re-add photos the target visit already has (dedupe on rescan/restore).
        let alreadyAttached = Set(target.photos.map(\.localIdentifier))
        let newAssets = cluster.assets.filter { !alreadyAttached.contains($0.localIdentifier) }
        // Capture cloud identifiers now so they sync *with* the visit (a second device can otherwise
        // receive the visit before them and show empty tiles). No-op when iCloud Photos is off.
        let cloudIDs = await PhotoLibraryLinker.cloudIdentifiers(
            forLocalIdentifiers: newAssets.map(\.localIdentifier)
        )
        for asset in newAssets {
            let photo = PhotoAsset(
                localIdentifier: asset.localIdentifier,
                takenAt: asset.creationDate ?? cluster.startDate,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isVideo: asset.mediaType == .video
            )
            photo.photoCloudIdentifier = cloudIDs[asset.localIdentifier]
            photo.visit = target
            context.insert(photo)
        }
    }

    private func requestPhotoAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Preload every prior screening result into a `[localIdentifier: isDining]` map so the
    /// gate can check the cache with a dictionary lookup instead of a per-photo fetch.
    private func loadScreenCache(in context: ModelContext) throws -> [String: ScreenedPhoto] {
        let screened = try context.fetch(FetchDescriptor<ScreenedPhoto>())
        return Dictionary(
            screened.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    /// Local identifiers of photos the user has dismissed (by deleting a visit). These are skipped
    /// so a deleted visit isn't recreated on the next scan.
    private func loadDismissedIDs(in context: ModelContext) throws -> Set<String> {
        let descriptor = FetchDescriptor<ScreenedPhoto>(predicate: #Predicate { $0.dismissed })
        return Set(try context.fetch(descriptor).map { $0.localIdentifier })
    }

    /// The classifier version whose negatives have already been swept. When the classifier version
    /// is newer than this, the next scan does a one-time full sweep to re-check negatives.
    private var lastNegativeRescanVersion: Int {
        get { UserDefaults.standard.integer(forKey: "lastNegativeRescanVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "lastNegativeRescanVersion") }
    }

    /// Identifiers of photos already imported into a visit — skipped so scans never duplicate.
    /// A recent, live visit at the same restaurant whose photos fall within the clustering time gap
    /// of this cluster — i.e. the same meal, captured across multiple scans.
    private func mergeableVisit(for restaurant: Restaurant, cluster: PhotoCluster) -> Visit? {
        let gapLimit = PhotoClusteringService.maxTimeGapSeconds
        return restaurant.visits.first { visit in
            guard visit.deletedAt == nil else { return false }
            let times = visit.photos.map(\.takenAt)
            let visitStart = times.min() ?? visit.date
            let visitEnd = times.max() ?? visit.date
            // Gap between the two time intervals (0 when they overlap).
            let gap = max(
                cluster.startDate.timeIntervalSince(visitEnd),
                visitStart.timeIntervalSince(cluster.endDate),
                0
            )
            return gap <= gapLimit
        }
    }

    /// The live visit that already owns one of this cluster's photos, if any — so a rescan (e.g.
    /// after an iCloud restore repopulated visits) reuses it instead of creating a duplicate.
    private func visitClaimingAnyPhoto(in cluster: PhotoCluster, context: ModelContext) -> Visit? {
        let ids = cluster.assets.map(\.localIdentifier)
        guard !ids.isEmpty else { return nil }
        var descriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        descriptor.fetchLimit = 10
        guard let matches = try? context.fetch(descriptor) else { return nil }
        return matches.lazy.compactMap { $0.visit }.first { $0.deletedAt == nil }
    }

    private func loadImportedIDs(in context: ModelContext) throws -> Set<String> {
        let photos = try context.fetch(FetchDescriptor<PhotoAsset>())
        return Set(photos.map { $0.localIdentifier })
    }

    private func latestPhotoDate(in context: ModelContext) throws -> Date? {
        var descriptor = FetchDescriptor<PhotoAsset>(
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.takenAt
    }
}
