import SwiftUI

struct PhotoThumbnailView: View {
    let localIdentifier: String
    var targetSize: CGSize = CGSize(width: 300, height: 300)

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView())
            }
        }
        .task(id: localIdentifier) {
            image = await PhotoThumbnailLoader.loadThumbnail(
                localIdentifier: localIdentifier,
                targetSize: targetSize
            )
        }
    }
}
