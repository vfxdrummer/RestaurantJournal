import SwiftUI
import SwiftData

/// The user's Top 10 restaurants, ranked by `RestaurantRanking` (ratings + how often they've been).
/// Phase 1: a derived list — no comparisons yet, no stored score.
struct TopTenView: View {
    @Query private var restaurants: [Restaurant]

    private var ranked: [Restaurant] { RestaurantRanking.top(restaurants) }

    var body: some View {
        Group {
            if ranked.isEmpty {
                ContentUnavailableView(
                    "No Top 10 yet",
                    systemImage: "trophy",
                    description: Text("Rate your visits 😋 and the places you love — and keep going back to — rise to the top here.")
                )
            } else {
                List {
                    Section {
                        ForEach(Array(ranked.enumerated()), id: \.element.persistentModelID) { index, restaurant in
                            row(rank: index + 1, restaurant: restaurant)
                        }
                    } footer: {
                        Text("Ranked from your ratings and how often you've visited. Rate more meals to sharpen it.")
                    }
                }
            }
        }
        .navigationTitle("Your Top 10")
        .navigationBarTitleDisplayMode(.inline)
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

    private func subtitle(city: String?, visitCount: Int) -> String {
        let visitText = "\(visitCount) visit\(visitCount == 1 ? "" : "s")"
        if let city, !city.isEmpty { return "\(city) · \(visitText)" }
        return visitText
    }
}
