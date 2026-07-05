import Foundation
import Photos
import Vision
import UIKit

/// On-device screening that decides whether a photo (or a cluster of photos) looks
/// like a restaurant visit — food on the table, or people gathered around one.
///
/// Uses Apple's Vision framework (`VNClassifyImageRequest` + `VNDetectFaceRectanglesRequest`),
/// so there's no Core ML model to ship and everything runs on the Neural Engine.
/// If the built-in taxonomy proves too coarse, a dedicated food classifier can be
/// dropped in behind this same interface later.
enum RestaurantPhotoClassifier {

    // MARK: - Tunables

    /// Include the "people posing around a table" signal (≥2 faces + a dining context
    /// label). Set to `false` to run food-only if faces cause too many false positives.
    static var includePeopleAroundTableSignal = true

    /// A face count at or above this, combined with a dining-context label, counts as a
    /// dining photo even without food in frame.
    static var minimumFacesForGathering = 2

    /// Precision/recall gate applied to each Vision label before we trust it. Vision's
    /// per-label precision/recall calibration is more robust than a raw confidence value.
    /// Loosen (lower precision) to catch more food; tighten to cut false positives.
    static var labelMinPrecision: Float = 0.5
    static var labelForRecall: Float = 0.5

    /// Longest edge (points) of the downsampled image handed to Vision. Small keeps it fast;
    /// food/scene classification doesn't need full resolution.
    static var analysisMaxDimension: CGFloat = 299

    // MARK: - Signals

    struct Signals {
        let hasFood: Bool
        let faceCount: Int
        let hasDiningContext: Bool

        var isDining: Bool {
            if hasFood { return true }
            if RestaurantPhotoClassifier.includePeopleAroundTableSignal,
               faceCount >= RestaurantPhotoClassifier.minimumFacesForGathering,
               hasDiningContext {
                return true
            }
            return false
        }
    }

    // MARK: - Per-photo classification

    static func signals(for asset: PHAsset) async -> Signals {
        guard let cgImage = await loadImage(for: asset, maxDimension: analysisMaxDimension) else {
            return Signals(hasFood: false, faceCount: 0, hasDiningContext: false)
        }
        return await withCheckedContinuation { continuation in
            // Vision's `perform` is synchronous and CPU-heavy — keep it off the caller's thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                let classify = VNClassifyImageRequest()
                let faces = VNDetectFaceRectanglesRequest()

                do {
                    try handler.perform([classify, faces])
                } catch {
                    continuation.resume(returning: Signals(hasFood: false, faceCount: 0, hasDiningContext: false))
                    return
                }

                var hasFood = false
                var hasContext = false
                for observation in (classify.results ?? [])
                where observation.hasMinimumPrecision(labelMinPrecision, forRecall: labelForRecall) {
                    let identifier = observation.identifier.lowercased()
                    if !hasFood, foodLabelStems.contains(where: identifier.contains) {
                        hasFood = true
                    }
                    if !hasContext, diningContextStems.contains(where: identifier.contains) {
                        hasContext = true
                    }
                    if hasFood && hasContext { break }
                }

                let faceCount = faces.results?.count ?? 0
                continuation.resume(returning: Signals(hasFood: hasFood, faceCount: faceCount, hasDiningContext: hasContext))
            }
        }
    }

    // MARK: - Image loading

    private static func loadImage(for asset: PHAsset, maxDimension: CGFloat) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact

        let target = CGSize(width: maxDimension, height: maxDimension)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // .highQualityFormat delivers a single non-degraded callback; guard anyway.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed && (!isDegraded || image == nil) {
                    resumed = true
                    continuation.resume(returning: image?.cgImage)
                }
            }
        }
    }

    // MARK: - Label vocabularies (matched as substrings of Vision identifiers)

    /// Food and beverage labels — any match makes a photo dining-positive on its own.
    private static let foodLabelStems: Set<String> = [
        "food", "meal", "cuisine", "dish", "fruit", "vegetable", "dessert", "cake", "pie",
        "bread", "pastry", "bakery", "baked", "pizza", "burger", "hamburger", "cheeseburger",
        "sandwich", "sushi", "sashimi", "salad", "soup", "stew", "noodle", "pasta", "spaghetti",
        "ramen", "rice", "curry", "taco", "burrito", "dumpling", "hotdog", "hot_dog", "steak",
        "meat", "beef", "pork", "chicken", "poultry", "seafood", "fish", "shrimp", "lobster",
        "crab", "egg", "omelet", "pancake", "waffle", "cheese", "chocolate", "candy", "cookie",
        "donut", "doughnut", "ice_cream", "icecream", "barbecue", "bbq", "breakfast", "brunch",
        "lunch", "dinner", "snack",
        // Beverages
        "beverage", "drink", "cocktail", "wine", "beer", "champagne", "whiskey", "liquor",
        "coffee", "espresso", "latte", "cappuccino", "tea", "juice", "smoothie", "soda"
    ]

    /// Setting/tableware labels — only meaningful alongside the people-around-a-table signal.
    private static let diningContextStems: Set<String> = [
        "table", "dining", "restaurant", "cafe", "cafeteria", "bar", "pub", "diner", "bistro",
        "tableware", "plate", "bowl", "cutlery", "glassware", "tablecloth", "banquet", "feast",
        "buffet"
    ]
}
