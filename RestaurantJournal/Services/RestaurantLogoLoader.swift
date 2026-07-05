import Foundation
import UIKit

/// Fetches an establishment's icon/logo directly from its own website (no third-party
/// service). Tries, in order: the conventional `apple-touch-icon`, any `<link rel="icon">`
/// declared on the homepage, then `favicon.ico`. Pure network layer — persistence and caching
/// live in `EstablishmentLogoStore`. Returns the raw bytes + the URL they came from, or `nil`
/// when nothing usable is found.
enum RestaurantLogoLoader {

    struct FetchedIcon {
        let data: Data
        let source: URL
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Fetch strategy

    static func fetchIcon(host: String) async -> FetchedIcon? {
        // 1. Conventional apple-touch-icon at the root — usually a clean square PNG.
        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] {
            if let url = URL(string: "https://\(host)\(path)"),
               let icon = await loadImageData(from: url) {
                return icon
            }
        }
        // 2. Icon declared in the homepage's <head>.
        if let iconURL = await declaredIconURL(host: host),
           let icon = await loadImageData(from: iconURL) {
            return icon
        }
        // 3. Last resort: favicon.ico (often small / low quality, may fail to decode).
        if let url = URL(string: "https://\(host)/favicon.ico"),
           let icon = await loadImageData(from: url) {
            return icon
        }
        return nil
    }

    private static func loadImageData(from url: URL) async -> FetchedIcon? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            // Guard against soft-404 HTML pages served with a 200 status.
            guard UIImage(data: data) != nil else { return nil }
            return FetchedIcon(data: data, source: http.url ?? url)
        } catch {
            return nil
        }
    }

    private static func declaredIconURL(host: String) async -> URL? {
        guard let homeURL = URL(string: "https://\(host)/") else { return nil }
        do {
            let (data, response) = try await session.data(from: homeURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            let base = http.url ?? homeURL   // resolve relative hrefs against the final (post-redirect) URL
            guard let href = bestIconHref(in: html) else { return nil }
            return URL(string: href, relativeTo: base)?.absoluteURL
        } catch {
            return nil
        }
    }

    // MARK: - Lightweight HTML scraping

    /// Scan `<link rel="...icon...">` tags and return the best href, preferring apple-touch-icon.
    private static func bestIconHref(in html: String) -> String? {
        let pattern = #"<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var appleTouch: String?
        var generic: String?
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: html) else { return }
            let tag = String(html[r])
            guard let href = attribute("href", in: tag) else { return }
            let rel = (attribute("rel", in: tag) ?? "").lowercased()
            if rel.contains("apple-touch-icon") {
                if appleTouch == nil { appleTouch = href }
            } else if generic == nil {
                generic = href
            }
        }
        return appleTouch ?? generic
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let r = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }
}
