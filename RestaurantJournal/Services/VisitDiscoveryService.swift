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

    enum Phase {
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

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    var isBusy: Bool { phase == .scanning || phase == .paused }

    // MARK: - Pause state (not observed)

    @ObservationIgnored private var isPaused = false
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

    private func waitWhilePaused() async {
        if isPaused {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pauseWaiters.append(continuation)
            }
        }
    }

    // MARK: - Scan

    func scan(in context: ModelContext) async {
        guard !isBusy else { return }

        phase = .scanning
        processed = 0
        total = 0
        newVisitCount = 0
        errorMessage = nil

        // 1. Photo library authorization
        let status = await requestPhotoAuth()
        guard status == .authorized || status == .limited else {
            errorMessage = "Photo library access is required to discover restaurant visits."
            phase = .finished
            return
        }

        do {
            // 2. Scan only photos newer than the latest already-imported one.
            let latestImportedDate = try latestPhotoDate(in: context)

            // 3. Fetch + 4. cluster.
            let assets = PhotoClusteringService.fetchAssets(since: latestImportedDate)
            guard !assets.isEmpty else { phase = .finished; return }
            total = assets.count
            let clusters = PhotoClusteringService.cluster(assets)

            var screenCache = try loadScreenCache(in: context)
            let dismissedIds = try loadDismissedIDs(in: context)

            // 5. Per cluster: gate on dining evidence, look up a restaurant, insert a Visit.
            for cluster in clusters {
                await waitWhilePaused()
                let clusterBase = processed

                var diningMatches = 0
                var looksLikeDining = false
                for asset in cluster.assets {
                    let id = asset.localIdentifier
                    let isDining: Bool
                    if dismissedIds.contains(id) {
                        // The user deleted a visit containing this photo — never resurrect it.
                        isDining = false
                    } else if let cached = screenCache[id] {
                        isDining = cached
                    } else {
                        isDining = await RestaurantPhotoClassifier.signals(for: asset).isDining
                        screenCache[id] = isDining
                        context.insert(ScreenedPhoto(localIdentifier: id, isDining: isDining))
                    }
                    processed += 1
                    if isDining {
                        diningMatches += 1
                        if diningMatches >= Self.minimumDiningPhotosPerCluster {
                            looksLikeDining = true
                            break
                        }
                    }
                }
                // Count photos skipped by the early break so progress still reaches 100%.
                processed = clusterBase + cluster.assets.count

                if looksLikeDining {
                    let candidates = await RestaurantLookupService.lookup(near: cluster.centroid)
                    if let best = candidates.first {
                        let restaurant = try RestaurantResolver.findOrCreate(from: best, in: context)
                        let visit = Visit(
                            date: cluster.startDate,
                            restaurant: restaurant,
                            latitude: cluster.centroid.latitude,
                            longitude: cluster.centroid.longitude
                        )
                        context.insert(visit)
                        for asset in cluster.assets {
                            let photo = PhotoAsset(
                                localIdentifier: asset.localIdentifier,
                                takenAt: asset.creationDate ?? cluster.startDate,
                                latitude: asset.location?.coordinate.latitude,
                                longitude: asset.location?.coordinate.longitude
                            )
                            photo.visit = visit
                            context.insert(photo)
                        }
                        newVisitCount += 1
                    }
                }

                // Persist after each cluster so an interrupted scan resumes cheaply.
                try? context.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        phase = .finished
    }

    // MARK: - Helpers

    private func requestPhotoAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Preload every prior screening result into a `[localIdentifier: isDining]` map so the
    /// gate can check the cache with a dictionary lookup instead of a per-photo fetch.
    private func loadScreenCache(in context: ModelContext) throws -> [String: Bool] {
        let screened = try context.fetch(FetchDescriptor<ScreenedPhoto>())
        return Dictionary(
            screened.map { ($0.localIdentifier, $0.isDining) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    /// Local identifiers of photos the user has dismissed (by deleting a visit). These are skipped
    /// so a deleted visit isn't recreated on the next scan.
    private func loadDismissedIDs(in context: ModelContext) throws -> Set<String> {
        let descriptor = FetchDescriptor<ScreenedPhoto>(predicate: #Predicate { $0.dismissed })
        return Set(try context.fetch(descriptor).map { $0.localIdentifier })
    }

    private func latestPhotoDate(in context: ModelContext) throws -> Date? {
        var descriptor = FetchDescriptor<PhotoAsset>(
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.takenAt
    }
}
