import SwiftUI
import SwiftData
import UIKit

enum JournalMode: Hashable { case list, map }

struct JournalListView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Visit> { $0.deletedAt == nil },
        sort: \Visit.date,
        order: .reverse
    )
    private var visits: [Visit]

    @Query(filter: #Predicate<Visit> { $0.deletedAt != nil })
    private var deletedVisits: [Visit]

    @Query(filter: #Predicate<Restaurant> { $0.isIgnored })
    private var ignoredRestaurants: [Restaurant]

    @State private var scanner = VisitDiscoveryService()
    @State private var celebrationCount: Int?
    @State private var searchText = ""
#if ASK_FEATURE
    @State private var showingAsk = false
#endif
    @State private var showingProfile = false
    @State private var showingRescanConfirmation = false
    @State private var bulkPromptRestaurant: Restaurant?
    @State private var viewMode: JournalMode = .list
    @AppStorage("onlyVisitsWithPhotos") private var onlyVisitsWithPhotos = false
    /// Shared with the map so the rating filter carries across views.
    @AppStorage("visitRatingFilter") private var ratingFilterRaw = ""

    private var activeRatingFilter: VisitRating? {
        ratingFilterRaw.isEmpty ? nil : VisitRating(rawValue: ratingFilterRaw)
    }
    private var ratingSelection: Binding<VisitRating?> {
        Binding(get: { activeRatingFilter }, set: { ratingFilterRaw = $0?.rawValue ?? "" })
    }
    private var hasRatedVisits: Bool {
        visits.contains { $0.rating != nil }
    }
    /// The very first scan must run to completion (the onboarding moment); only afterwards can a
    /// scan be cancelled.
    @AppStorage("hasCompletedInitialScan") private var hasCompletedInitialScan = false
    @State private var recentlyDeleted: Visit?
    @State private var undoDismissTask: Task<Void, Never>?

    /// True once there are card-sourced (photo-less) visits — the only case where the photos-only
    /// filter changes anything, so we only surface the toggle then.
    private var hasPhotolessVisits: Bool {
        visits.contains { $0.photos.isEmpty }
    }

    private var filteredVisits: [Visit] {
        var base = onlyVisitsWithPhotos ? visits.filter { !$0.photos.isEmpty } : visits
        if let filter = activeRatingFilter {
            base = base.filter { $0.rating == filter }
        }
        let tokens = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return base }
        return base.filter { visit in
            let haystack = searchHaystack(for: visit)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// The filtered visits grouped into month/year sections, preserving newest-first order.
    private var groupedVisits: [(title: String, visits: [Visit])] {
        var groups: [(title: String, visits: [Visit])] = []
        for visit in filteredVisits {
            let title = Self.monthFormatter.string(from: visit.date)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].visits.append(visit)
            } else {
                groups.append((title, [visit]))
            }
        }
        return groups
    }

    private func searchHaystack(for visit: Visit) -> String {
        var parts: [String] = []
        if let restaurant = visit.restaurant {
            parts.append(restaurant.name)
            [restaurant.address, restaurant.city, restaurant.region, restaurant.country]
                .compactMap { $0 }
                .forEach { parts.append($0) }
        }
        if let occasion = visit.occasion { parts.append(occasion) }
        if let note = visit.userNote { parts.append(note) }
        parts.append(contentsOf: visit.voiceNotes.compactMap { $0.transcript })
        return parts.joined(separator: " ").lowercased()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if visits.isEmpty {
                    // First run: one clear, branded call to action — no top bar to compete with it.
                    JournalWelcomeView(scanner: scanner) {
                        Task { await scanner.scan(in: modelContext) }
                    }
                } else {
                    switch viewMode {
                    case .list:
                        ScanStatusView(scanner: scanner, allowCancel: hasCompletedInitialScan) { fullRescan in
                            Task { await scanner.scan(in: modelContext, fullRescan: fullRescan) }
                        }
                        .background(.bar)
                        Divider()

                        List {
                            ForEach(groupedVisits, id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.visits) { visit in
                                        NavigationLink(destination: VisitDetailView(visit: visit)) {
                                            row(for: visit)
                                        }
                                    }
                                    .onDelete { offsets in deleteVisits(offsets, in: group.visits) }
                                }
                            }
                        }
                        .searchable(text: $searchText, prompt: "Search places, cities, countries…")
                        .overlay {
                            if filteredVisits.isEmpty && !searchText.isEmpty {
                                ContentUnavailableView.search(text: searchText)
                            }
                        }
                    case .map:
                        JournalMapView(scanner: scanner) {
                            Task { await scanner.scan(in: modelContext) }
                        }
                    }
                }
            }
            .navigationTitle("Journal")
            .overlay {
                if let count = celebrationCount {
                    ScanCelebrationView(count: count) {
                        withAnimation { celebrationCount = nil }
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: viewMode) { _, mode in
                if mode == .map { Analytics.log("map_opened") }
            }
            .onChange(of: scanner.phase) { _, phase in
                guard phase == .finished else { return }
                // (scan_completed is logged in VisitDiscoveryService with the full funnel.)
                // Now that the scan is idle, run iCloud maintenance (cloud-id + thumbnail backfill for
                // the new visits) — it deferred while the scan held the context.
                Task { await SyncMaintenance.run(context: modelContext) }
                // Once a scan finishes without error, the onboarding scan is done — later scans
                // (including Rescan All) may be cancelled from then on.
                if scanner.errorMessage == nil { hasCompletedInitialScan = true }
                if scanner.newVisitCount > 0 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { celebrationCount = scanner.newVisitCount }
                    Task {
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        withAnimation { celebrationCount = nil }
                    }
                }
            }
            .onAppear {
                // Existing testers who already have visits have effectively completed the first
                // scan — enable cancel for them without waiting for another full scan. Guarded on
                // `.idle` so it never flips on mid-first-scan when the view reappears.
                if !hasCompletedInitialScan, !visits.isEmpty, scanner.phase == .idle {
                    hasCompletedInitialScan = true
                }
            }
#if ASK_FEATURE
            .sheet(isPresented: $showingAsk) {
                AskJournalView()
            }
#endif
            .sheet(isPresented: $showingProfile) {
#if CARD_LINKING
                ProfileView()
#else
                AppSettingsView()
#endif
            }
            .task {
                await LocationBackfillService.backfillIfNeeded(in: modelContext)
            }
            .task {
                // Retire anything past its grace period on launch.
                VisitDeletion.purgeExpired(in: modelContext)
            }
            .toolbar {
#if ASK_FEATURE
                // Ask lives here now — a conversational overlay you summon from the journal, rather
                // than a permanent tab. Hidden until there are visits to ask about.
                if !visits.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingAsk = true
                        } label: {
                            Label("Ask", systemImage: "bubble.left.and.text.bubble.right.fill")
                        }
                    }
                }
#endif
                if !visits.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $viewMode) {
                            Image(systemName: "list.bullet").tag(JournalMode.list)
                            Image(systemName: "map").tag(JournalMode.map)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                }
                // Accounts live only in CARD_LINKING builds (an account exists to link a card).
                // The App Store build is account-free: this entry becomes a lightweight Settings.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingProfile = true
                    } label: {
#if CARD_LINKING
                        ProfileAvatarView(size: 34)
#else
                        Image(systemName: "gearshape").font(.title2)
#endif
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                            if hasRatedVisits {
                                Picker("Filter by rating", selection: ratingSelection) {
                                    Text("All ratings").tag(Optional<VisitRating>.none)
                                    ForEach(VisitRating.allCases) { rating in
                                        Text("\(rating.emoji)  \(rating.label)").tag(Optional(rating))
                                    }
                                }
                                Divider()
                            }
                            if hasPhotolessVisits {
                                Toggle(isOn: $onlyVisitsWithPhotos) {
                                    Label("Only visits with photos", systemImage: "photo")
                                }
                                Divider()
                            }
                            if !visits.isEmpty {
                                Button {
                                    showingRescanConfirmation = true
                                } label: {
                                    Label("Rescan all photos…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(scanner.isBusy)
                                Divider()
                            }
                            if !visits.isEmpty {
                                NavigationLink {
                                    RecapView()
                                } label: {
                                    Label("Your Review", systemImage: "calendar")
                                }
                                NavigationLink {
                                    TopTenView()
                                } label: {
                                    Label("Your Top 10", systemImage: "trophy")
                                }
                                NavigationLink {
                                    RewardsView()
                                } label: {
                                    Label("Rewards", systemImage: "gift")
                                }
                            }
                            NavigationLink {
                                RecentlyDeletedView()
                            } label: {
                                Label(
                                    deletedVisits.isEmpty
                                        ? "Recently Deleted"
                                        : "Recently Deleted (\(deletedVisits.count))",
                                    systemImage: "trash"
                                )
                            }
                            if !ignoredRestaurants.isEmpty {
                                NavigationLink {
                                    IgnoredPlacesView()
                                } label: {
                                    Label("Ignored Places (\(ignoredRestaurants.count))", systemImage: "nosign")
                                }
                            }
#if DEBUG
                            Divider()
                            NavigationLink {
                                DebugToolsView()
                            } label: {
                                Label("Test Lab (backup · reset · restore)", systemImage: "hammer")
                            }
#endif
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title2)
                        }
                    }
            }
            .overlay(alignment: .bottom) {
                if recentlyDeleted != nil {
                    undoBanner
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .confirmationDialog(
                "Rescan all photos?",
                isPresented: $showingRescanConfirmation,
                titleVisibility: .visible
            ) {
                Button("Rescan All") {
                    Task { await scanner.scan(in: modelContext, fullRescan: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Re-checks your entire photo library from the beginning to catch anything earlier scans missed. This can take a while. Your existing visits and deletions are kept.")
            }
            .confirmationDialog(
                "More visits at this place",
                isPresented: Binding(
                    get: { bulkPromptRestaurant != nil },
                    set: { if !$0 { bulkPromptRestaurant = nil } }
                ),
                titleVisibility: .visible,
                presenting: bulkPromptRestaurant
            ) { restaurant in
                Button("Delete all & stop detecting", role: .destructive) {
                    VisitDeletion.deleteAllAndIgnore(restaurant, in: modelContext)
                    bulkPromptRestaurant = nil
                }
                Button("Just this one", role: .cancel) { bulkPromptRestaurant = nil }
            } message: { restaurant in
                let count = restaurant.visits.filter { $0.deletedAt == nil }.count
                Text("There \(count == 1 ? "is" : "are") \(count) more visit\(count == 1 ? "" : "s") at \(restaurant.name). If this isn't a place you dine — say it's next to your home — remove them all and stop detecting it here.")
            }
        }
    }

    private var undoBanner: some View {
        HStack {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Visit deleted")
                .font(.subheadline)
            Spacer()
            Button("Undo", action: undoDelete)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    @ViewBuilder
    private func row(for visit: Visit) -> some View {
        HStack {
            if let photo = visit.coverPhoto {
                PhotoThumbnailView(
                    localIdentifier: photo.localIdentifier,
                    targetSize: CGSize(width: 120, height: 120),
                    fallbackData: visit.coverThumbnailData
                )
                .frame(width: 55, height: 55)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Card-sourced visits have no photo — show a card placeholder instead of a gap.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: 55, height: 55)
                    .overlay(
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                RestaurantNameLabel(restaurant: visit.restaurant)
                if let occ = visit.occasion, !occ.isEmpty {
                    Text(occ).font(.caption).foregroundStyle(.secondary)
                }
                Text(visit.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let rating = visit.rating {
                Spacer(minLength: 4)
                Text(rating.emoji).font(.title3)
            }
        }
    }

    private func deleteVisits(_ offsets: IndexSet, in sectionVisits: [Visit]) {
        let toDelete = offsets.map { sectionVisits[$0] }
        let restaurants = toDelete.compactMap { $0.restaurant }
        for visit in toDelete {
            VisitDeletion.delete(visit, in: modelContext)
        }
        // Arm an immediate one-tap undo for the last deletion (the common "oops" case). Anything
        // deleted still lives in Recently Deleted regardless.
        if let last = toDelete.last {
            armUndo(for: last)
        }
        // If a place still has other visits, it's likely a false-positive spot — offer to clean it
        // all up and stop detecting it (e.g. a restaurant next to the user's home).
        if let restaurant = restaurants.first(where: { r in
            !r.isIgnored && r.visits.contains { $0.deletedAt == nil }
        }) {
            bulkPromptRestaurant = restaurant
        }
    }

    private func armUndo(for visit: Visit) {
        undoDismissTask?.cancel()
        withAnimation { recentlyDeleted = visit }
        undoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                withAnimation { recentlyDeleted = nil }
            }
        }
    }

    private func undoDelete() {
        guard let visit = recentlyDeleted else { return }
        VisitDeletion.restore(visit, in: modelContext)
        undoDismissTask?.cancel()
        withAnimation { recentlyDeleted = nil }
    }
}
