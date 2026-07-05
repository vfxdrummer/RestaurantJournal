import SwiftUI

/// Scan trigger + live progress with pause/resume, driven by an observable `VisitDiscoveryService`.
struct ScanStatusView: View {
    let scanner: VisitDiscoveryService
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            switch scanner.phase {
            case .scanning, .paused:
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scanner.phase == .paused ? "Paused" : "Scanning photos…")
                            .font(.subheadline).bold()
                        Text("\(scanner.processed) of \(scanner.total) photos · \(scanner.newVisitCount) found")
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
                }
                ProgressView(value: scanner.progress)

            case .idle, .finished:
                Button(action: onScan) {
                    Label("Scan photo library", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if scanner.phase == .finished, scanner.newVisitCount > 0 {
                    Text("Added \(scanner.newVisitCount) visit\(scanner.newVisitCount == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
