import SwiftUI
import SwiftData
import MapKit

/// Maps an MKPointOfInterestCategory raw value to a category-appropriate SF Symbol, used as the
/// fallback when an establishment has no fetchable logo.
enum RestaurantCategoryIcon {
    static func symbolName(for rawValue: String?) -> String {
        guard let rawValue else { return "fork.knife" }
        switch MKPointOfInterestCategory(rawValue: rawValue) {
        case .cafe:       return "cup.and.saucer.fill"
        case .bakery:     return "birthday.cake.fill"
        case .brewery:    return "mug.fill"
        case .winery:     return "wineglass.fill"
        case .foodMarket: return "cart.fill"
        default:          return "fork.knife"   // .restaurant and anything else
        }
    }
}

/// A small square logo for an establishment, loaded from its website host. Falls back to a
/// category symbol chip (coffee cup, wine glass, …) while loading or when no icon is available.
struct RestaurantLogoView: View {
    let host: String?
    var name: String?
    var fallbackSystemImage: String = "fork.knife"
    var size: CGFloat = 20

    @Environment(\.modelContext) private var modelContext
    @State private var logo: UIImage?

    /// Process-wide cache so a logo that's already been fetched renders instantly when a pin is
    /// rebuilt (e.g. as the map re-clusters) — no fetch, no fallback flash.
    private static let cache = NSCache<NSString, UIImage>()

    private var taskID: String { "\(host ?? "")|\(name ?? "")" }

    /// Prefer the loaded image, but fall back to the cache so a freshly-created view shows the logo
    /// on its very first render instead of flashing the placeholder.
    private var displayImage: UIImage? { logo ?? Self.cache.object(forKey: taskID as NSString) }

    var body: some View {
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.gray.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: taskID) {
            if let cached = Self.cache.object(forKey: taskID as NSString) {
                logo = cached
                return
            }
            if let loaded = await EstablishmentLogoStore.logo(host: host, name: name, in: modelContext) {
                Self.cache.setObject(loaded, forKey: taskID as NSString)
                logo = loaded
            }
        }
    }
}

/// An establishment's logo shown inline with its name — used anywhere a restaurant name appears.
/// The logo falls back to a symbol matched to the establishment's category.
struct RestaurantNameLabel: View {
    let restaurant: Restaurant?
    var placeholder: String = "Unknown place"
    var font: Font = .headline
    var logoSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            RestaurantLogoView(
                host: restaurant?.websiteHost,
                name: restaurant?.name,
                fallbackSystemImage: RestaurantCategoryIcon.symbolName(for: restaurant?.categoryRawValue),
                size: logoSize
            )
            Text(restaurant?.name ?? placeholder)
                .font(font)
        }
    }
}
