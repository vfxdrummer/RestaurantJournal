import SwiftUI
import SwiftData

/// The user's Top 10 restaurants, ranked by `RestaurantRanking` (ratings + frequency seed, refined
/// by the comparison game). Searchable, so you can pull "Top 10 sushi" or "Top 10 in New York."
struct TopTenView: View {
    @Query private var restaurants: [Restaurant]
    @State private var searchText = ""

    private var query: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }

    private var ranked: [Restaurant] {
        let base = query.isEmpty ? restaurants : restaurants.filter { matches($0) }
        return RestaurantRanking.top(base, limit: 10)
    }

    var body: some View {
        Group {
            if ranked.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No Top 10 yet" : "No matches",
                    systemImage: query.isEmpty ? "trophy" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Rate your visits 😋 and the places you love — and keep going back to — rise to the top here."
                        : "No favorites match “\(searchText)”. Try a city or a place name.")
                )
            } else {
                List {
                    Section {
                        ForEach(Array(ranked.enumerated()), id: \.element.persistentModelID) { index, restaurant in
                            row(rank: index + 1, restaurant: restaurant)
                        }
                    } footer: {
                        Text(query.isEmpty
                            ? "Ranked from your ratings and how often you've visited. Tap Refine to sharpen it head-to-head."
                            : "Your best-loved places matching “\(searchText)”.")
                    }
                }
            }
        }
        .navigationTitle("Your Top 10")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "sushi, New York…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RankingGameView()
                } label: {
                    Label("Refine", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    @ViewBuilder
    private func row(rank: Int, restaurant: Restaurant) -> some View {
        let visits = RestaurantRanking.liveVisits(for: restaurant)
        let cover = visits.max { $0.date < $1.date }   // most recent live visit → its photo

        NavigationLink {
            if let cover { VisitDetailView(visit: cover) }
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.title2.weight(.heavy).monospacedDigit())
                    .foregroundStyle(rank <= 3 ? Color.accentColor : .secondary)
                    .frame(width: 28, alignment: .center)

                if let photo = cover?.coverPhoto {
                    PhotoThumbnailView(
                        localIdentifier: photo.localIdentifier,
                        targetSize: CGSize(width: 120, height: 120),
                        fallbackData: cover?.coverThumbnailData
                    )
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "fork.knife").foregroundStyle(.secondary))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(restaurant.name).font(.headline).lineLimit(1)
                    Text(subtitle(city: restaurant.city, visitCount: visits.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func matches(_ r: Restaurant) -> Bool {
        if r.name.lowercased().contains(query) { return true }
        for field in [r.city, r.region, r.country] where field?.lowercased().contains(query) == true {
            return true
        }
        for v in RestaurantRanking.liveVisits(for: r) {
            if v.userNote?.lowercased().contains(query) == true { return true }
            if v.occasion?.lowercased().contains(query) == true { return true }
        }
        return false
    }

    private func subtitle(city: String?, visitCount: Int) -> String {
        let visitText = "\(visitCount) visit\(visitCount == 1 ? "" : "s")"
        if let city, !city.isEmpty { return "\(city) · \(visitText)" }
        return visitText
    }
}
