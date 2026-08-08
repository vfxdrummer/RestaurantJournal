import Photos
import PhotosUI   // presentLimitedLibraryPicker(from:completionHandler:) is a PhotosUI category on
                 // PHPhotoLibrary — without importing (and thus autolinking) PhotosUI, the selector
                 // isn't registered at runtime and tapping "Add more photos" crashes.
import UIKit

/// Thin wrapper over the photo-library authorization state, plus the two limited-access affordances
/// iOS gives us: the "add more photos" picker and a deep link to Settings. Scanning already works in
/// limited mode — `PHAsset.fetchAssets` returns just the user-selected subset — so this exists purely
/// to help the user understand and expand that subset.
@MainActor
enum PhotoLibraryAccess {

    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static var isLimited: Bool { status == .limited }

    /// Photos currently visible to the app: the selected subset under `.limited`, the whole library
    /// under `.authorized`. Count-only, so it's cheap even on large libraries.
    static func visibleAssetCount() -> Int {
        PHAsset.fetchAssets(with: nil).count
    }

    /// Present iOS's limited-library picker so the user can add more photos to the shared set without
    /// leaving the app. `onAdded` receives how many photos were newly selected (0 if they added none).
    static func presentLimitedPicker(onAdded: @escaping (Int) -> Void) {
        guard let vc = topViewController() else { onAdded(0); return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc) { newIdentifiers in
            Task { @MainActor in onAdded(newIdentifiers.count) }
        }
    }

    /// Full access can't be granted from inside the app once limited is chosen — only Settings can.
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
