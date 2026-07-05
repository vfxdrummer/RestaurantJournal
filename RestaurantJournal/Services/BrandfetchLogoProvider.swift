import Foundation
import UIKit

/// Fetches establishment logos from Brandfetch's Brand Search API. Each search result carries a
/// ready-to-use `icon` URL (a Brandfetch CDN asset) that downloads directly — unlike the Logo Link
/// CDN, which is Referer/domain-restricted and rejects non-browser requests. Returns the raw image
/// bytes + source URL, or `nil` when there's no confident match or Brandfetch isn't configured.
///
/// Requires a Brandfetch **Search/Brand API client ID** (free, from
/// https://developers.brandfetch.com). It's a public client identifier, not a secret. Read from
/// the `BRANDFETCH_CLIENT_ID` environment variable or Info.plist key. Empty = disabled.
enum BrandfetchLogoProvider {

    /// Public Brandfetch Search API client ID. Compiled in as the default (it's a public embed
    /// identifier, not a secret); `BRANDFETCH_CLIENT_ID` in the environment or Info.plist overrides
    /// it if you want to swap keys without recompiling.
    static let clientID: String = {
        if let env = ProcessInfo.processInfo.environment["BRANDFETCH_CLIENT_ID"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "BRANDFETCH_CLIENT_ID") as? String,
           !plist.isEmpty {
            return plist
        }
        return "9JlwTYOGaa4aDBwP7zn0Hyg1WKN_FPtxoBW2iNWbBOhneSMhNz4KxmaRt44UUM2eBZKYxgRB6bWnY-ElNNCqPQ"
    }()

    static var isEnabled: Bool { !clientID.isEmpty }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Public

    static func fetchIcon(host: String?, name: String?) async -> RestaurantLogoLoader.FetchedIcon? {
        guard isEnabled, let name, !name.isEmpty else { return nil }
        guard let results = await search(query: name), !results.isEmpty else { return nil }
        guard let match = bestMatch(results, host: host, name: name),
              let iconURLString = match.icon,
              let url = URL(string: iconURLString) else { return nil }
        return await downloadImage(from: url)
    }

    // MARK: - Match selection

    /// Prefer a result whose domain matches the establishment's known website. Otherwise accept the
    /// top result only if it shares a meaningful token with the query name — this avoids slapping a
    /// national brand's logo onto a generically-named local spot ("The Diner", "Corner Cafe", …).
    private static func bestMatch(_ results: [SearchResult], host: String?, name: String) -> SearchResult? {
        if let host = host?.lowercased(), !host.isEmpty {
            if let exact = results.first(where: { r in
                guard let domain = r.domain?.lowercased() else { return false }
                return domain == host || host.hasSuffix(domain) || domain.hasSuffix(host)
            }) {
                return exact
            }
        }

        let queryTokens = tokens(name)
        guard !queryTokens.isEmpty else {
            return results.first(where: { $0.icon?.isEmpty == false })
        }
        return results.first { r in
            guard r.icon?.isEmpty == false else { return false }
            let domainWords = (r.domain ?? "").replacingOccurrences(of: ".", with: " ")
            let resultTokens = tokens(r.name ?? "").union(tokens(domainWords))
            return !queryTokens.isDisjoint(with: resultTokens)
        }
    }

    private static let stopWords: Set<String> = [
        "the", "cafe", "café", "restaurant", "bar", "grill", "kitchen", "eatery", "bistro",
        "diner", "co", "and", "pub", "house"
    ]

    private static func tokens(_ string: String) -> Set<String> {
        Set(
            string.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    // MARK: - Brand Search API

    private struct SearchResult: Decodable {
        let name: String?
        let domain: String?
        let icon: String?
    }

    private static func search(query: String) async -> [SearchResult]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://api.brandfetch.io/v2/search/\(encoded)") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "c", value: clientID)]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode([SearchResult].self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Download

    private static func downloadImage(from url: URL) async -> RestaurantLogoLoader.FetchedIcon? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  UIImage(data: data) != nil else { return nil }
            return RestaurantLogoLoader.FetchedIcon(data: data, source: http.url ?? url)
        } catch {
            return nil
        }
    }
}
