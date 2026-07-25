import Foundation
import Photos
import SwiftData
import Observation

/// Drives a scan and exposes its progress to the UI. The heavy lifting — screening (Vision) and
/// place-matching — runs on a background `ScanEngine` (its own `ModelContext`), so saves and the
/// CloudKit mirroring they trigger happen off the main thread and never freeze the scan. This type
/// just kicks it off, mirrors progress snapshots into observable state, and relays pause/cancel.
@MainActor
@Observable
final class VisitDiscoveryService {

    enum Phase: Equatable {
        case idle, scanning, paused, finished
    }

    /// How many dining-positive photos a cluster needs before it's accepted as a restaurant visit.
    /// `nonisolated` so the background `ScanEngine` can read it.
    nonisolated static let minimumDiningPhotosPerCluster = 1

    // MARK: - Observable progress

    private(set) var phase: Phase = .idle
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var newVisitCount = 0
    private(set) var errorMessage: String?
    private(set) var summary: String?
    /// Second, concurrent stage: places matched vs. dining clusters found so far.
    private(set) var matchProcessed = 0
    private(set) var matchTotal = 0

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    var matchProgress: Double { matchTotal > 0 ? Double(matchProcessed) / Double(matchTotal) : 0 }
    var isBusy: Bool { phase == .scanning || phase == .paused }

    /// True while *any* scan is running. Read by background maintenance (`SyncMaintenance`) so it
    /// doesn't run at the same time as a scan.
    @MainActor private(set) static var isScanning = false

    @ObservationIgnored private var control: ScanControl?

    // MARK: - Pause / cancel

    func pause() {
        guard phase == .scanning else { return }
        control?.setPaused(true)
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        control?.setPaused(false)
        phase = .scanning
    }

    /// Stop the scan early. Visits already found are kept (they're saved in batches); the engine
    /// observes the flag and winds down, then `scan` flips to `.finished`.
    func cancel() {
        guard phase == .scanning || phase == .paused else { return }
        control?.cancel()
        control?.setPaused(false)
        phase = .scanning
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

        let status = await requestPhotoAuth()
        guard status == .authorized || status == .limited else {
            errorMessage = "Photo library access is required to discover restaurant visits."
            phase = .finished
            return
        }

        let control = ScanControl()
        self.control = control
        let engine = ScanEngine(modelContainer: context.container)
        let report: @Sendable (ScanSnapshot) async -> Void = { [weak self] snapshot in
            await MainActor.run { self?.apply(snapshot) }
        }

        let outcome = await engine.run(doFull: fullRescan, control: control, report: report)

        if outcome.noNewPhotos {
            summary = "No new photos to import."
        } else if outcome.cancelled {
            summary = "Scan stopped · added \(outcome.newVisitCount) visit\(outcome.newVisitCount == 1 ? "" : "s") so far."
        } else {
            summary = "Scanned \(outcome.scannedPhotoCount) new photo\(outcome.scannedPhotoCount == 1 ? "" : "s") · added \(outcome.newVisitCount) visit\(outcome.newVisitCount == 1 ? "" : "s")."
        }
        // A full sweep that finished marks negatives up to date for this classifier version.
        if outcome.completedFullSweep {
            lastNegativeRescanVersion = RestaurantPhotoClassifier.version
        }
        Analytics.log("scan_completed", [
            "photos_scanned": outcome.scannedPhotoCount,
            "visits_added": outcome.newVisitCount,
            "cancelled": outcome.cancelled,
            "full_rescan": fullRescan,
        ])
        self.control = nil
        phase = .finished
    }

    private func apply(_ snapshot: ScanSnapshot) {
        processed = snapshot.processed
        total = snapshot.total
        matchProcessed = snapshot.matchProcessed
        matchTotal = snapshot.matchTotal
        newVisitCount = snapshot.newVisitCount
    }

    private func requestPhotoAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// The classifier version whose negatives have already been swept. When the classifier version
    /// is newer than this, the next scan does a one-time full sweep to re-check negatives.
    private var lastNegativeRescanVersion: Int {
        get { UserDefaults.standard.integer(forKey: "lastNegativeRescanVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "lastNegativeRescanVersion") }
    }
}
