import SwiftUI

/// Scan trigger + live progress with pause/resume, driven by an observable `VisitDiscoveryService`.
/// Screening photos and matching places run concurrently, so each gets its own progress bar.
struct ScanStatusView: View {
    let scanner: VisitDiscoveryService
    /// Whether the scan can be cancelled. The first-run onboarding scan must complete in full, so
    /// this is `false` until the user has finished one scan.
    let allowCancel: Bool
    /// `true` = full rescan (ignore the incremental window, re-check the whole library).
    let onScan: (Bool) -> Void

    /// Observed so the throttle message appears/disappears live.
    @State private var geo = GeoLookupCoordinator.shared

    var body: some View {
        VStack(spacing: 10) {
            switch scanner.phase {
            case .scanning, .paused:
                HStack {
                    Text(scanner.phase == .paused ? "Paused" : "Scanning your library")
                        .font(.subheadline).bold()
                    Spacer()
                    Button {
                        if scanner.phase == .paused { scanner.resume() } else { scanner.pause() }
                    } label: {
                        Label(
                            scanner.phase == .paused ? "Resume" : "Pause",
                            systemImage: scanner.phase == .paused ? "play.fill" : "pause.fill"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    if allowCancel {
                        Button(role: .destructive) {
                            scanner.cancel()
                        } label: {
                            Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }

                // Stage 1 — screening photos (CPU-bound, fast).
                progressRow(
                    title: "Scanning photos",
                    detail: "\(scanner.processed) of \(scanner.total)",
                    value: scanner.progress
                )

                // Stage 2 — matching places (runs at the same time, paced by MapKit's limit).
                progressRow(
                    title: "Matching places",
                    detail: scanner.matchTotal > 0
                        ? "\(scanner.newVisitCount)/\(scanner.matchTotal) found"
                        : "\(scanner.newVisitCount) found",
                    value: scanner.matchProgress
                )

                if geo.isThrottled {
                    Text("Matching throttled by Apple (max 50 per minute)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .idle, .finished:
                Button {
                    onScan(false)
                } label: {
                    Label("Scan photo library", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if scanner.phase == .finished, let summary = scanner.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let error = scanner.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func progressRow(title: String, detail: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: value)
        }
    }
}
