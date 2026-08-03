import StoreKit
import UIKit

/// Asks for an App Store rating at a genuine moment of delight — after a *return* scan that added new
/// visits — and only when the user has enough history to have gotten real value. We ask at most once
/// per marketing version; the system ultimately decides whether to show the prompt and rate-limits it
/// (≈3×/year), so this just picks good moments to request.
///
/// Note: the prompt only actually appears in **App Store** builds. In TestFlight it does nothing, and
/// in development it's inconsistent — so this can't be verified before release, only the trigger logic.
enum RatingPrompt {
    private static let versionKey = "ratingPromptVersion"

    /// Minimum live visits before we'd ever ask — enough that the app has clearly delivered value.
    private static let minimumHistory = 5

    @MainActor
    static func maybePrompt(newVisits: Int, totalVisits: Int) {
        guard newVisits > 0 else { return }                 // only on a delight moment
        guard totalVisits >= minimumHistory else { return }  // not a brand-new user
        guard UserDefaults.standard.string(forKey: versionKey) != appVersion else { return } // once/version

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        UserDefaults.standard.set(appVersion, forKey: versionKey)
        AppStore.requestReview(in: scene)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
