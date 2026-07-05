import Foundation

extension Restaurant {
    /// An official Google Maps link to the place, by name + address. Opens the Google Maps app or
    /// web to the business without needing a Google Places API key.
    var googleMapsURL: URL? {
        var query = name
        if let address, !address.isEmpty {
            query += ", \(address)"
        }
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query)
        ]
        return components?.url
    }
}
