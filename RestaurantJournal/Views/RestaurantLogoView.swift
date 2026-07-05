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

    private var taskID: String { "\(host ?? "")|\(name ?? "")" }

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
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
            logo = nil
            logo = await EstablishmentLogoStore.logo(host: host, name: name, in: modelContext)
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
