import SwiftUI
import SwiftData

/// The "which was better?" comparison game — a few taps refine the Top 10 (ELO) on top of the
/// ratings/frequency seed. Pairs are drawn from the top contenders and are close in current score
/// (the uncertain, high-value matchups), so a handful of taps meaningfully sharpens the list.
struct RankingGameView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var restaurants: [Restaurant]

    @State private var pair: [Restaurant] = []      // exactly two, or empty
    @State private var comparisons = 0
    @State private var recentKeys: [String] = []

    var body: some View {
        VStack(spacing: 18) {
            if pair.count == 2 {
                Text("Which was better?")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)

                HStack(spacing: 12) {
                    card(pair[0]) { choose(winner: 0) }
                    card(pair[1]) { choose(winner: 1) }
                }
                .padding(.horizontal)

                Button { withAnimation { nextPair() } } label: {
                    Label("Too close to call", systemImage: "equal.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                if comparisons > 0 {
                    Text("\(comparisons) compared this session — your Top 10 is getting sharper")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                ContentUnavailableView(
                    "Not enough places to compare",
                    systemImage: "square.on.square",
                    description: Text("Scan or rate a few more restaurants, then come back to rank your favorites head-to-head.")
                )
            }
        }
        .navigationTitle("Refine your Top 10")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if pair.isEmpty { nextPair() } }
    }

    @ViewBuilder
    private func card(_ restaurant: Restaurant, onTap: @escaping () -> Void) -> some View {
        let cover = RestaurantRanking.liveVisits(for: restaurant).max { $0.date < $1.date }
        Button(action: onTap) {
            VStack(spacing: 0) {
                Group {
                    if let photo = cover?.coverPhoto {
                        PhotoThumbnailView(
                            localIdentifier: photo.localIdentifier,
                            targetSize: CGSize(width: 400, height: 400),
                            fallbackData: cover?.coverThumbnailData
                        )
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .overlay(Image(systemName: "fork.knife").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
                .frame(height: 170)
                .clipped()

                VStack(spacing: 2) {
                    Text(restaurant.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let city = restaurant.city, !city.isEmpty {
                        Text(city).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func choose(winner: Int) {
        guard pair.count == 2 else { return }
        RestaurantRanking.recordComparison(winner: pair[winner], loser: pair[1 - winner], in: modelContext)
        comparisons += 1
        withAnimation { nextPair() }
    }

    private func nextPair() {
        let ranked = RestaurantRanking.eligible(restaurants)
            .sorted { RestaurantRanking.effectiveScore(for: $0) > RestaurantRanking.effectiveScore(for: $1) }
        guard ranked.count >= 2 else { pair = []; return }

        // Draw from the top contenders and prefer adjacent-in-ranking pairs (close scores = the
        // uncertain matchups that most sharpen the Top 10). Avoid pairs we just showed.
        let pool = Array(ranked.prefix(min(ranked.count, 24)))
        for _ in 0..<16 {
            let i = Int.random(in: 0..<(pool.count - 1))
            let a = pool[i], b = pool[i + 1]
            let key = pairKey(a, b)
            if !recentKeys.contains(key) {
                pair = Bool.random() ? [a, b] : [b, a]   // randomize sides to avoid position bias
                remember(key)
                return
            }
        }
        let i = Int.random(in: 0..<(pool.count - 1))
        pair = [pool[i], pool[i + 1]]
    }

    private func pairKey(_ a: Restaurant, _ b: Restaurant) -> String {
        [a.name, b.name].sorted().joined(separator: "|")
    }

    private func remember(_ key: String) {
        recentKeys.append(key)
        if recentKeys.count > 10 { recentKeys.removeFirst() }
    }
}
