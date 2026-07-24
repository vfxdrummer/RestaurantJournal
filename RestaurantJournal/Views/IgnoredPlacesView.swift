import SwiftUI
import SwiftData

/// The places the user told the app to stop detecting, with a way to turn detection back on. This
/// is the reversibility valve for "Stop detecting this place" — otherwise it'd be a one-way door.
struct IgnoredPlacesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Restaurant> { $0.isIgnored }, sort: \Restaurant.name)
    private var places: [Restaurant]

    var body: some View {
        Group {
            if places.isEmpty {
                ContentUnavailableView(
                    "Nothing Ignored",
                    systemImage: "eye",
                    description: Text("Places you tell the app to stop detecting will show up here, so you can turn them back on.")
                )
            } else {
                List {
                    Section {
                        ForEach(places) { place in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                    if let city = place.city, !city.isEmpty {
                                        Text(city).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Resume") { resume(place) }
                                    .buttonStyle(.borderless)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    } footer: {
                        Text("Resuming lets future scans detect a place again. It doesn't bring back visits you already deleted — recover those from Recently Deleted.")
                    }
                }
            }
        }
        .navigationTitle("Ignored Places")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resume(_ place: Restaurant) {
        place.isIgnored = false
        try? modelContext.save()
    }
}
