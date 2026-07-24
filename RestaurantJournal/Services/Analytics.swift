import Foundation

/// Fire-and-forget, privacy-respecting product analytics. Events are anonymous (keyed by a random
/// per-install id, never the user account), carry no photos/financial data, and never block the UI.
enum Analytics {
    /// Opt-out switch (default on). Wire a Settings toggle to this when desired.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "analyticsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "analyticsEnabled") }
    }

    /// Whether the user currently has an account. Segments behavior by auth state *without* ever
    /// attaching the account id — analytics stays anonymous (install-keyed). Kept in sync by
    /// `SupabaseAuthService`.
    static var isAuthenticated = false

    /// One id per app launch (process) — lets us compute per-session metrics like "locations viewed
    /// per session." Resets on a cold launch, persists across backgrounding.
    static let sessionID = UUID().uuidString

    static func log(_ name: String, _ props: [String: Any] = [:]) {
        guard isEnabled else { return }
        var enriched = props
        enriched["authenticated"] = isAuthenticated
        enriched["session"] = sessionID
        let payload: [String: Any] = [
            "install_id": installID,
            "name": name,
            "props": enriched,
            "app_version": appVersion,
        ]
        guard let url = URL(string: "\(SupabaseConfig.projectURL.absoluteString)/rest/v1/events"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer") // no row echoed back (no SELECT needed)
        request.httpBody = body

        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }

    // MARK: - Anonymous identity + version

    private static var installID: String {
        let key = "analyticsInstallID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
