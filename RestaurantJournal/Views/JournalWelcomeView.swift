import SwiftUI

/// First-run hero shown while the journal is empty: a branded invitation to kick off the very
/// first scan — the moment the user's dining history appears from photos they already have.
struct JournalWelcomeView: View {
    let scanner: VisitDiscoveryService
    let onScan: () -> Void
    /// Full rescan, triggered after a limited-access user adds more photos (they can predate the
    /// incremental window). Optional so existing call sites without limited handling still compile.
    var onFullRescan: () -> Void = {}

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

            VStack(spacing: 10) {
                Text("Your dining life, remembered.")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Restaurant Journal finds every place you've eaten straight from the photos you already have — no typing, no check-ins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Group {
                if scanner.isBusy {
                    VStack(spacing: 8) {
                        ProgressView(value: scanner.progress)
                        Text("Finding your restaurants… \(scanner.newVisitCount) so far")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: onScan) {
                        Label("Scan my photos", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)

            if scanner.phase == .finished, let summary = scanner.summary, scanner.newVisitCount == 0 {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // A limited-access user who scanned and got nothing back would otherwise dead-end here.
            // Give them the escape hatch: add more photos (or go full access) and rescan.
            if scanner.phase == .finished, !scanner.isBusy, PhotoLibraryAccess.isLimited {
                LimitedAccessBanner { onFullRescan() }
                    .padding(.horizontal, 24)
            }
            if let error = scanner.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
    }
}
