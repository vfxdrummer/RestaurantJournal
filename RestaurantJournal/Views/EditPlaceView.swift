import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// Correct a wrong restaurant match: shows nearby food POIs, live address/place autocomplete with a
/// map preview, and a custom-name fallback.
struct EditPlaceView: View {
    @Bindable var visit: Visit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [RestaurantCandidate] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @StateObject private var completer = AddressSearchCompleter()
    @State private var pendingCandidate: RestaurantCandidate?
    @State private var isResolving = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var applyToAll = false

    /// How many live visits currently share this visit's restaurant (including this one).
    private var siblingVisitCount: Int {
        visit.restaurant?.visits.filter { $0.deletedAt == nil }.count ?? 1
    }

    private var origin: CLLocation? {
        visit.lookupCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The coordinate the map pins: a chosen suggestion, else the visit's own location.
    private var displayCoordinate: CLLocationCoordinate2D? {
        pendingCandidate?.coordinate ?? visit.lookupCoordinate
    }

    private var displayName: String {
        pendingCandidate?.name ?? visit.restaurant?.name ?? "Here"
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            List {
                if displayCoordinate != nil {
                    Section {
                        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                            if let coord = displayCoordinate {
                                Marker(displayName, coordinate: coord)
                            }
                        }
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if siblingVisitCount > 1, let name = visit.restaurant?.name {
                    Section {
                        Toggle("Apply to all \(siblingVisitCount) visits at this place", isOn: $applyToAll)
                    } footer: {
                        Text("Move every visit currently matched to \(name) to the new place, not just this one.")
                    }
                }

                Section("Find a place") {
                    TextField("Search name or address", text: $searchText)
                        .autocorrectionDisabled()
                        .onChange(of: searchText) { _, newValue in
                            completer.update(query: newValue)
                        }

                    if isResolving {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Locating…").foregroundStyle(.secondary)
                        }
                    }

                    ForEach(completer.suggestions, id: \.self) { suggestion in
                        Button {
                            Task { await previewSuggestion(suggestion) }
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if !trimmedSearch.isEmpty && completer.suggestions.isEmpty && !isResolving {
                        Button {
                            useCustomName(trimmedSearch)
                        } label: {
                            Label("Use “\(trimmedSearch)” as the name", systemImage: "pencil")
                        }
                    }
                }

                if let pending = pendingCandidate {
                    Section("Selected") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.name).font(.headline)
                            if let address = pending.address {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            select(pending)
                        } label: {
                            Label("Use this place", systemImage: "checkmark.circle.fill")
                        }
                    }
                }

                if isLoading {
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } else if !candidates.isEmpty {
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
            }
            .navigationTitle("Change place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: configureForVisit)
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

    private func configureForVisit() {
        guard let coord = visit.lookupCoordinate else { return }
        cameraPosition = .region(
            MKCoordinateRegion(center: coord, latitudinalMeters: 400, longitudinalMeters: 400)
        )
        // Bias autocomplete to a wide area around the visit so local places rank first.
        completer.setRegion(
            MKCoordinateRegion(center: coord, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        )
    }

    private func loadCandidates() async {
        isLoading = true
        defer { isLoading = false }
        guard let coordinate = visit.lookupCoordinate else { return }
        candidates = await RestaurantLookupService.lookup(near: coordinate, in: modelContext)
    }

    private func previewSuggestion(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }
        guard let item = await completer.resolve(completion) else { return }
        let candidate = RestaurantLookupService.candidate(from: item)
        pendingCandidate = candidate
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: candidate.coordinate,
                    latitudinalMeters: 400,
                    longitudinalMeters: 400
                )
            )
        }
    }

    private func select(_ candidate: RestaurantCandidate) {
        guard let restaurant = try? RestaurantResolver.findOrCreate(from: candidate, in: modelContext) else { return }
        apply(restaurant)
    }

    private func useCustomName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let coordinate = pendingCandidate?.coordinate ?? visit.lookupCoordinate
        let restaurant = Restaurant(
            name: name,
            latitude: coordinate?.latitude ?? 0,
            longitude: coordinate?.longitude ?? 0
        )
        modelContext.insert(restaurant)
        apply(restaurant)
    }

    /// Reassign the visit's restaurant — just this one, or every visit currently sharing it when the
    /// user toggled "apply to all" (bulk-fixing a mis-detected place like a spot next to their home).
    private func apply(_ newRestaurant: Restaurant) {
        if applyToAll, let old = visit.restaurant {
            for sibling in old.visits.filter({ $0.deletedAt == nil }) {
                sibling.restaurant = newRestaurant
            }
        } else {
            visit.restaurant = newRestaurant
        }
        try? modelContext.save()
        print("[sync] place changed → \(newRestaurant.name)\(applyToAll ? " (applied to all siblings)" : "") — saved, will export")
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
