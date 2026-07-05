import SwiftUI
import SwiftData
import CoreLocation

/// Correct a wrong restaurant match: shows the nearby food POIs at the visit's location and lets
/// the user pick the right one, or enter a custom name via "Other".
struct EditPlaceView: View {
    @Bindable var visit: Visit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [RestaurantCandidate] = []
    @State private var isLoading = true
    @State private var customName = ""

    private var origin: CLLocation? {
        visit.lookupCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if candidates.isEmpty {
                    Text("No nearby places found.")
                        .foregroundStyle(.secondary)
                }

                if !candidates.isEmpty {
                    Section("Nearby places") {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                            Button {
                                select(candidate)
                            } label: {
                                candidateRow(candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Other") {
                    HStack {
                        TextField("Enter a place name", text: $customName)
                        Button("Use") { useCustomName() }
                            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Change place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadCandidates() }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: RestaurantCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let address = candidate.address {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let distance = distanceText(to: candidate) {
                Text(distance)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if isCurrentSelection(candidate) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Actions

    private func loadCandidates() async {
        isLoading = true
        defer { isLoading = false }
        guard let coordinate = visit.lookupCoordinate else { return }
        candidates = await RestaurantLookupService.lookup(near: coordinate)
    }

    private func select(_ candidate: RestaurantCandidate) {
        guard let restaurant = try? RestaurantResolver.findOrCreate(from: candidate, in: modelContext) else { return }
        visit.restaurant = restaurant
        try? modelContext.save()
        dismiss()
    }

    private func useCustomName() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let coordinate = visit.lookupCoordinate
        let restaurant = Restaurant(
            name: name,
            latitude: coordinate?.latitude ?? 0,
            longitude: coordinate?.longitude ?? 0
        )
        modelContext.insert(restaurant)
        visit.restaurant = restaurant
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Helpers

    private func isCurrentSelection(_ candidate: RestaurantCandidate) -> Bool {
        guard let current = visit.restaurant else { return false }
        if let id = candidate.mapItemIdentifier, id == current.mapItemIdentifier { return true }
        return candidate.name == current.name
    }

    private func distanceText(to candidate: RestaurantCandidate) -> String? {
        guard let origin else { return nil }
        let meters = origin.distance(from: CLLocation(
            latitude: candidate.coordinate.latitude,
            longitude: candidate.coordinate.longitude
        ))
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }
}
