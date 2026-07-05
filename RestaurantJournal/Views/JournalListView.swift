import SwiftUI
import SwiftData

struct JournalListView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Visit.date, order: .reverse)])
    private var visits: [Visit]

    @State private var scanner = VisitDiscoveryService()
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScanStatusView(scanner: scanner, onScan: startScan)
                    .background(.bar)
                Divider()

                Group {
                    if visits.isEmpty {
                        ContentUnavailableView(
                            "Your journal is empty",
                            systemImage: "book.closed",
                            description: Text("Tap Scan to find restaurant visits in your photos. Swipe any entry to remove it.")
                        )
                    } else {
                        List {
                            ForEach(visits) { visit in
                                NavigationLink(destination: VisitDetailView(visit: visit)) {
                                    row(for: visit)
                                }
                            }
                            .onDelete(perform: deleteVisits)
                        }
                    }
                }
            }
            .navigationTitle("Journal")
#if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
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

    @ViewBuilder
    private func row(for visit: Visit) -> some View {
        HStack {
            if let photo = visit.photos.first {
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

    private func startScan() {
        Task { await scanner.scan(in: modelContext) }
    }

    private func deleteVisits(_ offsets: IndexSet) {
        for index in offsets {
            VisitDeletion.delete(visits[index], in: modelContext)
        }
    }
}
