import SwiftUI
import SwiftData

/// A warm look back at the dining you did in a month or a week — visits, first-time discoveries, the
/// places you love. Reflection, not a streak: it only ever celebrates what happened, never nags about
/// what didn't. The natural on-ramp to sharing (a future "share your month" card).
struct RecapView: View {
    @Query private var allVisits: [Visit]
    @State private var period: RecapPeriod = .month
    @State private var index = 0   // 0 = most recent period, increasing = older

    private var recaps: [Recap] {
        RecapService.availableRecaps(period, from: allVisits)
    }

    var body: some View {
        Group {
            if recaps.isEmpty {
                ContentUnavailableView(
                    "No review yet",
                    systemImage: "calendar",
                    description: Text("Log a few visits and your monthly and weekly reviews will appear here — a warm look back at where you've been eating.")
                )
            } else {
                let recap = recaps[min(index, recaps.count - 1)]
                ScrollView {
                    VStack(spacing: 20) {
                        periodBar(current: recap)
                        RecapCard(recap: recap)
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Your Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Period", selection: $period) {
                    ForEach(RecapPeriod.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
        }
        .onChange(of: period) { _, _ in index = 0 }   // switching cadence returns to the latest
        .onAppear {
            Analytics.log("recap_opened", ["period": period.rawValue, "periods_available": recaps.count])
        }
    }

    /// ‹ Older / title / Newer › — step through the periods that actually have visits.
    @ViewBuilder
    private func periodBar(current recap: Recap) -> some View {
        HStack {
            Button {
                if index < recaps.count - 1 { index += 1 }   // older
            } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            .disabled(index >= recaps.count - 1)

            Spacer()
            VStack(spacing: 2) {
                Text(recap.title).font(.headline)
                if recaps.count > 1 {
                    Text(index == 0 ? "Most recent" : "\(index) \(period.noun)\(index == 1 ? "" : "s") ago")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()

            Button {
                if index > 0 { index -= 1 }   // newer
            } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
            .disabled(index == 0)
        }
        .padding(.horizontal, 4)
    }
}

/// The body of one review — a stack of celebratory cards.
private struct RecapCard: View {
    let recap: Recap

    var body: some View {
        VStack(spacing: 20) {
            hero
            if !recap.collage.isEmpty { collage }
            statTiles
            if !ratingItems.isEmpty { ratingRow }
            if let top = recap.topPlace { favorite(top) }
            if !recap.newDiscoveries.isEmpty { discoveries }
            if !recap.cities.isEmpty { citiesRow }
        }
    }

    // MARK: Hero headline

    private var hero: some View {
        VStack(spacing: 6) {
            Text(headline)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subhead)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var headline: String {
        let n = recap.visitCount
        return "You dined out \(n) time\(n == 1 ? "" : "s") this \(recap.period.noun)."
    }

    private var subhead: String {
        var bits: [String] = []
        if recap.newDiscoveryCount > 0 {
            bits.append("\(recap.newDiscoveryCount) new place\(recap.newDiscoveryCount == 1 ? "" : "s")")
        }
        if recap.revisitCount > 0 {
            bits.append("\(recap.revisitCount) return\(recap.revisitCount == 1 ? "" : "s") to a favorite")
        }
        if bits.isEmpty { return "Here's your look back." }
        return bits.joined(separator: " · ")
    }

    // MARK: Photo collage

    private var collage: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recap.collage, id: \.persistentModelID) { visit in
                    if let photo = visit.coverPhoto {
                        PhotoThumbnailView(
                            localIdentifier: photo.localIdentifier,
                            targetSize: CGSize(width: 240, height: 240),
                            fallbackData: visit.coverThumbnailData
                        )
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(recap.visitCount)", label: "Visits", icon: "fork.knife", tint: .accentColor)
            StatTile(value: "\(recap.newDiscoveryCount)", label: recap.newDiscoveryCount == 1 ? "New place" : "New places", icon: "sparkles", tint: .accentColor)
            // Revisits = the north-star habit signal — give it the brand color.
            StatTile(value: "\(recap.revisitCount)", label: "Return visits", icon: "arrow.counterclockwise", tint: Color("BrandGreen"))
            StatTile(value: "\(recap.uniquePlaceCount)", label: recap.uniquePlaceCount == 1 ? "Place" : "Places", icon: "mappin.and.ellipse", tint: Color("BrandGreen"))
        }
    }

    // MARK: Ratings

    private var ratingItems: [(VisitRating, Int)] {
        VisitRating.allCases.compactMap { r in
            let c = recap.ratingCounts[r] ?? 0
            return c > 0 ? (r, c) : nil
        }
    }

    private var ratingRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("How it tasted").font(.headline)
                HStack(spacing: 20) {
                    ForEach(ratingItems, id: \.0) { rating, count in
                        VStack(spacing: 4) {
                            Text(rating.emoji).font(.title)
                            Text("\(count)").font(.title3.weight(.semibold).monospacedDigit())
                            Text(rating.label).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Favorite of the period

    private func favorite(_ restaurant: Restaurant) -> some View {
        let cover = RestaurantRanking.liveVisits(for: restaurant).max { $0.date < $1.date }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Your go-to this \(recap.period.noun)", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color("BrandGreen"))
                HStack(spacing: 12) {
                    if let photo = cover?.coverPhoto {
                        PhotoThumbnailView(
                            localIdentifier: photo.localIdentifier,
                            targetSize: CGSize(width: 160, height: 160),
                            fallbackData: cover?.coverThumbnailData
                        )
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.12))
                            .frame(width: 60, height: 60)
                            .overlay(Image(systemName: "fork.knife").foregroundStyle(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(restaurant.name).font(.headline).lineLimit(1)
                        if let city = restaurant.city, !city.isEmpty {
                            Text(city).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: New discoveries

    private var discoveries: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("New this \(recap.period.noun)", systemImage: "sparkles")
                    .font(.headline)
                ForEach(recap.newDiscoveries, id: \.persistentModelID) { restaurant in
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(restaurant.name).lineLimit(1)
                        Spacer()
                        if let city = restaurant.city, !city.isEmpty {
                            Text(city).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    // MARK: Cities

    private var citiesRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(recap.cities.count == 1 ? "Where you ate" : "Cities you explored", systemImage: "map")
                    .font(.headline)
                Text(recap.cities.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Small building blocks

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                Text(value).font(.title.weight(.bold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded surface used for every review section, so the whole screen reads as one system.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
