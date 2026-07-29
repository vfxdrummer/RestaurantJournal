import Foundation
import Photos
import UIKit

enum PhotoThumbnailLoader {
    /// Decoded-thumbnail cache so a row scrolling back into view is instant instead of re-hitting the
    /// Photos database + image pipeline every time (the source of list-scroll stutter). Keyed by
    /// identifier + target size.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    /// A caching image manager (vs. `.default()`) so repeat requests for the same assets are cheaper.
    private static let manager = PHCachingImageManager()

    private static func cacheKey(_ id: String, _ size: CGSize) -> NSString {
        "\(id)@\(Int(size.width))x\(Int(size.height))" as NSString
    }

    /// Load a downsampled UIImage for a given PHAsset local identifier, serving cached results first.
    static func loadThumbnail(
        localIdentifier: String,
        targetSize: CGSize
    ) async -> UIImage? {
        let key = cacheKey(localIdentifier, targetSize)
        if let cached = cache.object(forKey: key) { return cached }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(
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
                    if let image { cache.setObject(image, forKey: key) }
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
