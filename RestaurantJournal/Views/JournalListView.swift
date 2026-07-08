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

    @State private var scanner = VisitDiscoveryService()
    @State private var showResetConfirmation = false
    @State private var celebrationCount: Int?
    @State private var searchText = ""
    @State private var showingAsk = false
    @State private var showingRescanConfirmation = false
    @State private var viewMode: JournalMode = .list
    /// The very first scan must run to completion (the onboarding moment); only afterwards can a
    /// scan be cancelled.
    @AppStorage("hasCompletedInitialScan") private var hasCompletedInitialScan = false
    @State private var recentlyDeleted: Visit?
    @State private var undoDismissTask: Task<Void, Never>?

    private var filteredVisits: [Visit] {
        let tokens = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return visits }
        return visits.filter { visit in
            let haystack = searchHaystack(for: visit)
            return tokens.allSatisfy { haystack.contains($0) }
        }
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
                            ForEach(filteredVisits) { visit in
                                NavigationLink(destination: VisitDetailView(visit: visit)) {
                                    row(for: visit)
                                }
                            }
                            .onDelete(perform: deleteVisits)
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
            .onChange(of: scanner.phase) { _, phase in
                guard phase == .finished else { return }
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
            .sheet(isPresented: $showingAsk) {
                AskJournalView()
            }
            .task {
                await LocationBackfillService.backfillIfNeeded(in: modelContext)
            }
            .task {
                // Retire anything past its grace period on launch.
                VisitDeletion.purgeExpired(in: modelContext)
            }
            .toolbar {
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
                // Reachable even when the journal is empty but the trash isn't, so a tester who
                // deleted everything can still find their way back.
                if !visits.isEmpty || !deletedVisits.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if !visits.isEmpty {
                                Button {
                                    showingRescanConfirmation = true
                                } label: {
                                    Label("Rescan all photos…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(scanner.isBusy)
                                Divider()
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
#if DEBUG
                            Divider()
                            Button(role: .destructive) {
                                showResetConfirmation = true
                            } label: {
                                Label("Reset All Data…", systemImage: "exclamationmark.arrow.circlepath")
                            }
#endif
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
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
#if DEBUG
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    DataResetService.resetAll(in: modelContext)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all visits, restaurants, screening and logo caches, and voice notes. For testing ingestion from scratch.")
            }
#endif
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
                    targetSize: CGSize(width: 120, height: 120)
                )
                .frame(width: 55, height: 55)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        }
    }

    private func deleteVisits(_ offsets: IndexSet) {
        let shown = filteredVisits
        let toDelete = offsets.map { shown[$0] }
        for visit in toDelete {
            VisitDeletion.delete(visit, in: modelContext)
        }
        // Arm an immediate one-tap undo for the last deletion (the common "oops" case). Anything
        // deleted still lives in Recently Deleted regardless.
        if let last = toDelete.last {
            armUndo(for: last)
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
