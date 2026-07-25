import SwiftUI

/// Scan trigger + live progress with pause/resume, driven by an observable `VisitDiscoveryService`.
struct ScanStatusView: View {
    let scanner: VisitDiscoveryService
    /// Whether the scan can be cancelled. The first-run onboarding scan must complete in full, so
    /// this is `false` until the user has finished one scan.
    let allowCancel: Bool
    /// `true` = full rescan (ignore the incremental window, re-check the whole library).
    let onScan: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            switch scanner.phase {
            case .scanning, .paused:
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scanner.phase == .paused ? "Paused" : scanner.stageDescription)
                            .font(.subheadline).bold()
                        Text("\(scanner.processed) of \(scanner.total) · \(scanner.newVisitCount) found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                            Label("Cancel", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                ProgressView(value: scanner.progress)

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
}
