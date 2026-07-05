import Foundation
import Photos
import UIKit

enum PhotoThumbnailLoader {
    /// Load a downsampled UIImage for a given PHAsset local identifier.
    static func loadThumbnail(
        localIdentifier: String,
        targetSize: CGSize
    ) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery calls back multiple times; only resume on the final,
                // non-degraded image (or on nil to avoid hanging).
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed && (!isDegraded || image == nil) {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Load a full, high-quality (aspect-fit) image suitable for sharing.
    static func loadShareImage(
        localIdentifier: String,
        maxDimension: CGFloat = 1600
    ) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact

        let targetSize = CGSize(width: maxDimension, height: maxDimension)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed && (!isDegraded || image == nil) {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
