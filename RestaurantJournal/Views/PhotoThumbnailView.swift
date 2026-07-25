import SwiftUI

struct PhotoThumbnailView: View {
    let localIdentifier: String
    var targetSize: CGSize = CGSize(width: 300, height: 300)
    /// A synced JPEG (e.g. `Visit.coverThumbnailData`) shown when the original photo isn't on this
    /// device — so a journal restored to a new iPhone renders instead of showing blank cards.
    var fallbackData: Data? = nil

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let fallback = fallbackData.flatMap(UIImage.init(data:)) {
                Image(uiImage: fallback)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView())
            }
        }
        .task(id: localIdentifier) {
            // Only replace the fallback if the live photo actually loads (don't clear to nil).
            if let loaded = await PhotoThumbnailLoader.loadThumbnail(
                localIdentifier: localIdentifier,
                targetSize: targetSize
            ) {
                image = loaded
            }
        }
    }
}
