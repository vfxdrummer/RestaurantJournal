import Foundation
import Photos
import CoreLocation

struct PhotoCluster {
    let assets: [PHAsset]
    let centroid: CLLocationCoordinate2D
    let startDate: Date
    let endDate: Date
}

enum PhotoClusteringService {
    /// Max time gap between consecutive photos in the same cluster
    static let maxTimeGapSeconds: TimeInterval = 90 * 60
    /// Max distance (meters) between consecutive photos in the same cluster
    static let maxDistanceMeters: CLLocationDistance = 150
    /// Minimum photos required to consider a cluster a "visit" candidate
    static let minPhotosPerCluster: Int = 1

    /// Fetch all photo library assets that have location + were taken since `since`.
    static func fetchAssets(since: Date? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let since {
            predicates.append(NSPredicate(format: "creationDate > %@", since as NSDate))
        }
        // Only images (skip videos for MVP)
        predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.location != nil { assets.append(asset) }
        }
        return assets
    }

    /// Cluster assets by time + spatial proximity.
    static func cluster(_ assets: [PHAsset]) -> [PhotoCluster] {
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }

        var clusters: [[PHAsset]] = []
        var current: [PHAsset] = []

        for asset in sorted {
            guard
                let last = current.last,
                let lastLoc = last.location,
                let currLoc = asset.location,
                let lastDate = last.creationDate,
                let currDate = asset.creationDate
            else {
                current = [asset]
                continue
            }

            let timeGap = currDate.timeIntervalSince(lastDate)
            let distance = lastLoc.distance(from: currLoc)

            if timeGap <= maxTimeGapSeconds && distance <= maxDistanceMeters {
                current.append(asset)
            } else {
                if current.count >= minPhotosPerCluster { clusters.append(current) }
                current = [asset]
            }
        }
        if current.count >= minPhotosPerCluster { clusters.append(current) }

        return clusters.compactMap { assets in
            guard let first = assets.first, let last = assets.last,
                  let firstDate = first.creationDate, let lastDate = last.creationDate
            else { return nil }

            let coords = assets.compactMap { $0.location?.coordinate }
            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)

            return PhotoCluster(
                assets: assets,
                centroid: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                startDate: firstDate,
                endDate: lastDate
            )
        }
    }
}
