import Foundation
import SwiftData
import UIKit

/// Disk-backed lookup of establishment logos, keyed by website host when known or by name
/// otherwise. Resolution order:
///   1. in-memory image cache (fastest, per session)
///   2. persisted `EstablishmentLogo` record (survives relaunches)
///   3. network fetch — Brandfetch first (by domain or name), then the site's own icon
///
/// A negative result is remembered (`isMissing`) and re-checked only after `missingRetryInterval`,
/// *and* is invalidated early if the set of enabled sources changes (e.g. Brandfetch is turned
/// on), so newly-available logos appear without a reinstall. Concurrent requests for the same key
/// share one in-flight task.
@MainActor
enum EstablishmentLogoStore {

    /// Re-check keys that previously returned no logo after this long.
    static var missingRetryInterval: TimeInterval = 60 * 60 * 24 * 30 // 30 days

    /// Identifies the currently-enabled logo sources. When it changes, prior negatives are stale.
    private static var sourceSignature: String {
        BrandfetchLogoProvider.isEnabled ? "brandfetch+site" : "site"
    }

    private static var memoryCache: [String: UIImage] = [:]
    private static var knownMissing: Set<String> = []
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Drop all in-memory logo state (used by the debug data reset).
    static func clearMemoryCache() {
        memoryCache.removeAll()
        knownMissing.removeAll()
        inFlight.removeAll()
    }

    static func logo(host: String?, name: String?, in context: ModelContext) async -> UIImage? {
        guard let key = cacheKey(host: host, name: name) else { return nil }

        if let cached = memoryCache[key] { return cached }
        if knownMissing.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await resolve(key: key, host: host, name: name, in: context) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Keying

    /// Prefer the website host; fall back to a normalized name so name-based sources still work
    /// when MapKit gave us no URL.
    private static func cacheKey(host: String?, name: String?) -> String? {
        if let host, !host.isEmpty { return host }
        if let name, !name.isEmpty { return "name:" + name.lowercased() }
        return nil
    }

    // MARK: - Resolution

    private static func resolve(key: String, host: String?, name: String?, in context: ModelContext) async -> UIImage? {
        let record = try? fetchRecord(key: key, in: context)

        if let record {
            if let data = record.imageData, let image = UIImage(data: data) {
                memoryCache[key] = image
                return image
            }
            // Honor a negative result only while it's fresh AND the source set is unchanged.
            if record.isMissing,
               record.missSignature == sourceSignature,
               Date().timeIntervalSince(record.fetchedAt) < missingRetryInterval {
                knownMissing.insert(key)
                return nil
            }
        }

        let fetched = await fetchAny(host: host, name: name)
        persist(fetched: fetched, key: key, existing: record, in: context)

        if let fetched, let image = UIImage(data: fetched.data) {
            memoryCache[key] = image
            return image
        }
        knownMissing.insert(key)
        return nil
    }

    /// Try each source in priority order.
    private static func fetchAny(host: String?, name: String?) async -> RestaurantLogoLoader.FetchedIcon? {
        // 1. Brandfetch — best quality, and the only source that works from a name alone.
        if let icon = await BrandfetchLogoProvider.fetchIcon(host: host, name: name) {
            return icon
        }
        // 2. The establishment's own site icon (needs a domain).
        if let host, !host.isEmpty, let icon = await RestaurantLogoLoader.fetchIcon(host: host) {
            return icon
        }
        return nil
    }

    // MARK: - Persistence

    private static func fetchRecord(key: String, in context: ModelContext) throws -> EstablishmentLogo? {
        var descriptor = FetchDescriptor<EstablishmentLogo>(predicate: #Predicate { $0.host == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func persist(
        fetched: RestaurantLogoLoader.FetchedIcon?,
        key: String,
        existing: EstablishmentLogo?,
        in context: ModelContext
    ) {
        let record: EstablishmentLogo
        if let existing {
            record = existing
        } else {
            record = EstablishmentLogo(host: key)
            context.insert(record)
        }
        record.imageData = fetched?.data
        record.resolvedIconURLString = fetched?.source.absoluteString
        record.isMissing = (fetched == nil)
        record.missSignature = fetched == nil ? sourceSignature : nil
        record.fetchedAt = Date()
        try? context.save()
    }
}
