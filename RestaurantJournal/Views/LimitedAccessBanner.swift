import SwiftUI

/// Shown to limited-access users. It does three jobs, in order of what earns trust: reassures them
/// their photos are *only* scanned on-device (nothing else), explains full access is the richer
/// experience, and offers the two moves iOS allows — add more photos (in-app picker) or open Settings
/// for full access. Adding photos calls `onPhotosAdded`; the caller kicks off a *full* rescan, since
/// newly selected photos can predate the incremental window.
struct LimitedAccessBanner: View {
    var onPhotosAdded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're on limited photo access")
                        .font(.caption.weight(.semibold))
                    Text("Your photos are only ever scanned on your device to find restaurants — nothing else, and they never leave your phone. Full access catches every visit automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button {
                    PhotoLibraryAccess.presentLimitedPicker { added in
                        if added > 0 { onPhotosAdded() }
                    }
                } label: {
                    Label("Add more photos", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Grant full access") { PhotoLibraryAccess.openSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
