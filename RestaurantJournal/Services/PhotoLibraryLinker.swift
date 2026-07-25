import Foundation
import Photos

/// Bridges between a photo's device-specific `PHAsset.localIdentifier` and its
/// `PHCloudIdentifier`, which is **stable across devices** that share the user's iCloud Photo
/// Library. This is what lets a journal synced from one iPhone re-link to the same photos on a
/// different iPhone (local identifiers differ across devices; cloud identifiers don't).
///
/// The PhotoKit mapping calls can touch the network/database, so they run off the main thread.
enum PhotoLibraryLinker {
    /// Maps device-local identifiers → cloud-identifier strings, for the ones that resolve.
    static func cloudIdentifiers(forLocalIdentifiers ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
            var out: [String: String] = [:]
            for (local, result) in mappings {
                if case .success(let cloud) = result { out[local] = cloud.stringValue }
            }
            return out
        }.value
    }

    /// Maps cloud-identifier strings → this device's local identifiers, for the ones that resolve
    /// here (i.e. the photo exists in this device's library).
    static func localIdentifiers(forCloudIdentifiers ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let cloudIDs = ids.map { PHCloudIdentifier(stringValue: $0) }
            let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIDs)
            var out: [String: String] = [:]
            for (cloud, result) in mappings {
                if case .success(let local) = result { out[cloud.stringValue] = local }
            }
            return out
        }.value
    }

    /// The subset of the given local identifiers that currently resolve to a photo on this device.
    static func existingLocalIdentifiers(from ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var present: Set<String> = []
            fetched.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            return present
        }.value
    }
}
