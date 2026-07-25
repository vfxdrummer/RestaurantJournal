import SwiftUI
import SwiftData
import MapKit
import Combine
import UIKit

/// A map of everywhere you've dined — logo pins (with a visit-count badge), zoom-aware clustering,
/// and a details card with directions + the visit history for the tapped place.
struct JournalMapView: View {
    let scanner: VisitDiscoveryService
    let onScan: () -> Void

    @Query private var restaurants: [Restaurant]
    @AppStorage("onlyVisitsWithPhotos") private var onlyVisitsWithPhotos = false

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selected: Restaurant?

    @StateObject private var locationManager = LocationManager()
    @State private var pendingRecenter = false
    @State private var showLocationDenied = false
    /// Shared with the list via AppStorage so "show my Yay places" carries across views.
    @AppStorage("visitRatingFilter") private var ratingFilterRaw = ""

    private var activeRatingFilter: VisitRating? {
        ratingFilterRaw.isEmpty ? nil : VisitRating(rawValue: ratingFilterRaw)
    }
    private var ratingSelection: Binding<VisitRating?> {
        Binding(get: { activeRatingFilter }, set: { ratingFilterRaw = $0?.rawValue ?? "" })
    }

    /// A restaurant's live visits that pass the active filters (photos-only and rating).
    private func matchingVisits(_ restaurant: Restaurant) -> [Visit] {
        restaurant.visits.filter { visit in
            guard visit.deletedAt == nil else { return false }
            if onlyVisitsWithPhotos && visit.photos.isEmpty { return false }
            if let filter = activeRatingFilter, visit.rating != filter { return false }
            return true
        }
    }

    /// Restaurants with a real coordinate and at least one visit passing the current filters.
    private var mappable: [Restaurant] {
        restaurants.filter { restaurant in
            (restaurant.latitude != 0 || restaurant.longitude != 0) && !matchingVisits(restaurant).isEmpty
        }
    }

    /// Whether any live visit is rated — the map's rating filter only appears then.
    private var hasRatedVisits: Bool {
        restaurants.contains { restaurant in
            restaurant.visits.contains { $0.deletedAt == nil && $0.rating != nil }
        }
    }

    var body: some View {
        Group {
            if mappable.isEmpty {
                // Same centered scan CTA as the list's empty state, so the two views stay in step.
                JournalWelcomeView(scanner: scanner, onScan: onScan)
            } else {
                mapContent
            }
        }
        .onAppear {
            if visibleRegion == nil, let region = boundingRegion(for: mappable) {
                visibleRegion = region
                cameraPosition = .region(region)
            }
        }
    }

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            ForEach(currentClusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    if cluster.isCluster {
                        Button {
                            withAnimation(.snappy) { zoomIn(on: cluster) }
                        } label: {
                            clusterPin(cluster)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cluster.restaurants.count) places")
                    } else if let restaurant = cluster.restaurants.first {
                        Button {
                            withAnimation(.snappy) { selected = restaurant }
                        } label: {
                            pin(for: restaurant, isSelected: isSelected(restaurant))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(restaurant.name)
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Animate the re-cluster so pins fade/scale on and off instead of snapping.
            withAnimation(.easeInOut(duration: 0.3)) {
                visibleRegion = context.region
            }
        }
        .mapControls {
            MapCompass()
        }
        .safeAreaInset(edge: .top) {
            if hasRatedVisits {
                ratingFilterBar
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    locateButton
                }
                if let selected {
                    RestaurantMapCard(restaurant: selected) {
                        withAnimation(.snappy) { self.selected = nil }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onReceive(locationManager.$lastLocation) { location in
            guard pendingRecenter, let location else { return }
            pendingRecenter = false
            withAnimation {
                let region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: 1500,
                    longitudinalMeters: 1500
                )
                cameraPosition = .region(region)
                visibleRegion = region
            }
        }
        .alert("Location Access Off", isPresented: $showLocationDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on location access in Settings to center the map on where you are.")
        }
    }

    private var ratingFilterBar: some View {
        Picker("Filter by rating", selection: ratingSelection) {
            Text("All").tag(Optional<VisitRating>.none)
            ForEach(VisitRating.allCases) { rating in
                Text(rating.emoji).tag(Optional(rating))
            }
        }
        .pickerStyle(.segmented)
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 320)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var locateButton: some View {
        Button(action: locateMe) {
            Image(systemName: "location.fill")
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .accessibilityLabel("Center on my location")
    }

    private func locateMe() {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            showLocationDenied = true
        case .notDetermined:
            pendingRecenter = true
            locationManager.requestWhenInUse()
        default:
            pendingRecenter = true
            locationManager.requestOneShotLocation()
        }
    }

    // MARK: - Pins

    /// The map marker: the same logo chip used in list rows, with a visit-count badge.
    private func pin(for restaurant: Restaurant, isSelected: Bool) -> some View {
        RestaurantLogoView(
            host: restaurant.websiteHost,
            name: restaurant.name,
            fallbackSystemImage: RestaurantCategoryIcon.symbolName(for: restaurant.categoryRawValue),
            size: isSelected ? 40 : 30
        )
        .padding(5)
        .background(Circle().fill(.background))
        .overlay(
            Circle().stroke(isSelected ? Color.accentColor : Color.white, lineWidth: isSelected ? 3 : 2)
        )
        .overlay(alignment: .topTrailing) {
            let count = liveVisitCount(restaurant)
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(.red))
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 7, y: -7)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .scaleEffect(isSelected ? 1.1 : 1.0)
    }

    private func clusterPin(_ cluster: MapCluster) -> some View {
        Text("\(cluster.restaurants.count)")
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }

    // MARK: - Clustering

    /// Group nearby places into a grid whose cell size scales with the current zoom, so places
    /// separate as you zoom in and merge as you zoom out.
    private var currentClusters: [MapCluster] {
        let region = visibleRegion ?? boundingRegion(for: mappable)
            ?? MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                  span: .init(latitudeDelta: 60, longitudeDelta: 60))
        let divisions = 7.0
        let cellLat = max(region.span.latitudeDelta / divisions, 0.0002)
        let cellLon = max(region.span.longitudeDelta / divisions, 0.0002)

        var buckets: [String: [Restaurant]] = [:]
        for restaurant in mappable {
            let row = (restaurant.latitude / cellLat).rounded(.down)
            let col = (restaurant.longitude / cellLon).rounded(.down)
            buckets["\(row)|\(col)", default: []].append(restaurant)
        }

        return buckets.map { _, group in
            let lat = group.map(\.latitude).reduce(0, +) / Double(group.count)
            let lon = group.map(\.longitude).reduce(0, +) / Double(group.count)
            // Identity is the (sorted) member set, not the grid cell — so a pin keeps the same
            // identity across re-clusterings and isn't torn down/rebuilt (which caused blinking).
            let id = group.map { "\($0.persistentModelID)" }.sorted().joined(separator: "|")
            return MapCluster(
                id: id,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                restaurants: group
            )
        }
    }

    private func zoomIn(on cluster: MapCluster) {
        let region = boundingRegion(for: cluster.restaurants)
            ?? MKCoordinateRegion(center: cluster.coordinate,
                                  span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01))
        // Only move the camera; `onMapCameraChange` re-clusters (animated) once it settles, so the
        // cluster splits into pins on arrival rather than before the fly-in.
        cameraPosition = .region(region)
    }

    // MARK: - Helpers

    private func isSelected(_ restaurant: Restaurant) -> Bool {
        selected?.persistentModelID == restaurant.persistentModelID
    }

    private func liveVisitCount(_ restaurant: Restaurant) -> Int {
        matchingVisits(restaurant).count
    }

    /// A region that frames the given places, with padding and a sensible minimum span.
    private func boundingRegion(for restaurants: [Restaurant]) -> MKCoordinateRegion? {
        guard !restaurants.isEmpty else { return nil }
        let lats = restaurants.map(\.latitude)
        let lons = restaurants.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.008),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.008)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// A grid-clustered group of one or more restaurants at a point on the map.
private struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let restaurants: [Restaurant]
    var isCluster: Bool { restaurants.count > 1 }
}

/// The details card shown when a single pin is tapped: logo, address, directions, and a link into
/// the visit history for that place.
private struct RestaurantMapCard: View {
    let restaurant: Restaurant
    let onClose: () -> Void

    private var liveVisits: [Visit] {
        restaurant.visits
            .filter { $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                RestaurantLogoView(
                    host: restaurant.websiteHost,
                    name: restaurant.name,
                    fallbackSystemImage: RestaurantCategoryIcon.symbolName(for: restaurant.categoryRawValue),
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(restaurant.name).font(.headline)
                    if let address = restaurant.address {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(visitSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                if let apple = restaurant.appleMapsURL {
                    Link(destination: apple) {
                        cardAction("Apple Maps", systemImage: "map.fill")
                    }
                }
                if let google = restaurant.googleMapsURL {
                    Link(destination: google) {
                        cardAction("Google", systemImage: "mappin.and.ellipse")
                    }
                }
            }

            if let latest = liveVisits.first {
                NavigationLink {
                    RestaurantVisitsView(restaurant: restaurant)
                } label: {
                    cardAction(
                        liveVisits.count > 1 ? "View \(liveVisits.count) visits" : "View visit",
                        systemImage: "book.fill",
                        prominent: true
                    )
                }
                .buttonStyle(.plain)
                // Keep the latest visit reachable for VoiceOver even if the label reads the count.
                .accessibilityHint(latest.date.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func cardAction(_ title: String, systemImage: String, prominent: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                (prominent ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .foregroundStyle(prominent ? Color.accentColor : Color.primary)
    }

    private var visitSummary: String {
        let count = liveVisits.count
        let times = "\(count) visit\(count == 1 ? "" : "s")"
        if let last = liveVisits.first?.date {
            return "\(times) · last \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        return times
    }
}

/// The full visit history for one restaurant, reached from the map card.
private struct RestaurantVisitsView: View {
    let restaurant: Restaurant

    private var visits: [Visit] {
        restaurant.visits
            .filter { $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            ForEach(visits) { visit in
                NavigationLink {
                    VisitDetailView(visit: visit)
                } label: {
                    HStack(spacing: 12) {
                        if let photo = visit.coverPhoto {
                            PhotoThumbnailView(
                                localIdentifier: photo.localIdentifier,
                                targetSize: CGSize(width: 120, height: 120),
                                fallbackData: visit.coverThumbnailData
                            )
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if let occasion = visit.occasion, !occasion.isEmpty {
                                Text(occasion).font(.subheadline)
                            }
                            Text(visit.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(restaurant.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
