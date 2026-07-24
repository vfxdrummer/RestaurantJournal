import SwiftUI
import SwiftData

struct VisitDetailView: View {
    @Bindable var visit: Visit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingRecorder = false
    @State private var showingEditPlace = false
    @State private var showingShare = false
    @State private var showingStopDetecting = false
    @State private var viewerPhotoID: String?
    @StateObject private var player = AudioPlayerService()
    @StateObject private var dishRecognizer = DishRecognizer()

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    private var restaurantVisitCount: Int {
        visit.restaurant?.visits.filter { $0.deletedAt == nil }.count ?? 1
    }

    /// Photos in this visit that Vision recognized as food.
    private var ateFoodPhotos: [PhotoAsset] {
        visit.photos.filter { !(dishRecognizer.results[$0.localIdentifier]?.isEmpty ?? true) }
    }

    /// Whether every photo has been analyzed (so we know to stop showing the spinner / hide section).
    private var dishesAllProcessed: Bool {
        visit.photos.allSatisfy { dishRecognizer.results[$0.localIdentifier] != nil }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(VisitRating.allCases) { rating in
                        ratingButton(rating)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }

            Section("Place") {
                if let r = visit.restaurant {
                    RestaurantNameLabel(restaurant: r, logoSize: 24)
                    if let addr = r.address { Text(addr).font(.caption).foregroundStyle(.secondary) }
                    if let apple = r.appleMapsURL {
                        Link(destination: apple) {
                            Label("Open in Apple Maps", systemImage: "map")
                        }
                    }
                    if let google = r.googleMapsURL {
                        Link(destination: google) {
                            Label("Open in Google Maps", systemImage: "mappin.and.ellipse")
                        }
                    }
                } else {
                    Text("Unknown restaurant").foregroundStyle(.secondary)
                }
                Text(visit.date.formatted(date: .complete, time: .shortened))
                    .font(.caption)

                if let amount = visit.amount {
                    Label(
                        amount.formatted(.currency(code: visit.currencyCode ?? "USD")),
                        systemImage: "creditcard"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button {
                    showingEditPlace = true
                } label: {
                    Label(visit.restaurant == nil ? "Set place" : "Wrong place? Change it",
                          systemImage: "mappin.and.ellipse")
                }
            }

            if let program = LoyaltyDirectory.program(for: visit.restaurant?.name) {
                Section {
                    LoyaltyNudgeCard(program: program, visitCount: restaurantVisitCount)
                }
            }

            if !ateFoodPhotos.isEmpty || !dishesAllProcessed {
                Section("What you ate here") {
                    if ateFoodPhotos.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Looking at your photos…").foregroundStyle(.secondary)
                        }
                    } else {
                        // Fixed-HEIGHT cells (not aspect-ratio): a fractional column width would give
                        // a fractional square height that rounds inconsistently and loops the layout.
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(ateFoodPhotos, id: \.localIdentifier) { photo in
                                Color.clear
                                    .frame(height: 110)
                                    .overlay {
                                        PhotoThumbnailView(
                                            localIdentifier: photo.localIdentifier,
                                            targetSize: CGSize(width: 300, height: 300)
                                        )
                                    }
                                    .overlay(alignment: .bottom) {
                                        let dish = (dishRecognizer.results[photo.localIdentifier] ?? []).joined(separator: ", ")
                                        if !dish.isEmpty {
                                            Text(dish)
                                                .font(.caption2).fontWeight(.medium)
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 3)
                                                .background(.black.opacity(0.45))
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture { viewerPhotoID = photo.localIdentifier }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
            }

            Section("Occasion") {
                TextField("e.g. Sarah's birthday, after the game", text: Binding(
                    get: { visit.occasion ?? "" },
                    set: { visit.occasion = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Notes") {
                TextField("Anything worth remembering?", text: Binding(
                    get: { visit.userNote ?? "" },
                    set: { visit.userNote = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(3...6)
            }

            Section("Voice notes") {
                ForEach(visit.voiceNotes, id: \.audioFilename) { note in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            player.toggle(note.audioURL)
                        } label: {
                            Image(systemName: player.isPlaying(note.audioURL) ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Transcript", text: Binding(
                                get: { note.transcript ?? "" },
                                set: {
                                    note.transcript = $0.isEmpty ? nil : $0
                                    try? modelContext.save()
                                }
                            ), axis: .vertical)
                            .lineLimit(1...6)
                            Text(note.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteVoiceNotes)

                Button {
                    showingRecorder = true
                } label: {
                    Label("Record voice note", systemImage: "mic.circle.fill")
                }
            }

            if !visit.photos.isEmpty {
                Section("Photos") {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(visit.photos, id: \.localIdentifier) { photo in
                            // A clear 1:1 square defines a deterministic cell size (width == height),
                            // with the photo overlaid and clipped. This avoids the unbounded
                            // ".aspectRatio(.fill)" that can trigger a UICollectionView layout loop.
                            Color.clear
                                .frame(height: 110)
                                .overlay {
                                    PhotoThumbnailView(
                                        localIdentifier: photo.localIdentifier,
                                        targetSize: CGSize(width: 300, height: 300)
                                    )
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topLeading) {
                                    if visit.coverPhoto?.localIdentifier == photo.localIdentifier {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(Color.accentColor, in: Circle())
                                            .padding(4)
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if photo.isVideo {
                                        Image(systemName: "play.circle.fill")
                                            .font(.body)
                                            .foregroundStyle(.white)
                                            .shadow(radius: 2)
                                            .padding(5)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { viewerPhotoID = photo.localIdentifier }
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
            }

            if let restaurant = visit.restaurant {
                Section {
                    Button(role: .destructive) {
                        showingStopDetecting = true
                    } label: {
                        Label("Stop detecting this place", systemImage: "nosign")
                    }
                } footer: {
                    Text("Removes all visits at \(restaurant.name) and stops detecting it in future scans — handy if it isn't a place you dine (say, it's next to your home).")
                }
            }
        }
        .navigationTitle(visit.restaurant?.name ?? "Visit")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Stop detecting this place?",
            isPresented: $showingStopDetecting,
            titleVisibility: .visible,
            presenting: visit.restaurant
        ) { restaurant in
            Button("Delete all & stop detecting", role: .destructive) {
                VisitDeletion.deleteAllAndIgnore(restaurant, in: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { restaurant in
            let count = restaurant.visits.filter { $0.deletedAt == nil }.count
            Text("This removes all \(count) visit\(count == 1 ? "" : "s") at \(restaurant.name) and stops future scans from detecting it. You can recover the visits from Recently Deleted.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShare = true
                } label: {
                    Label("Recommend", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingRecorder) {
            VoiceRecorderSheet(visit: visit)
        }
        .sheet(isPresented: $showingEditPlace) {
            EditPlaceView(visit: visit)
        }
        .sheet(isPresented: $showingShare) {
            ShareRecommendationView(visit: visit)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { viewerPhotoID != nil },
                set: { if !$0 { viewerPhotoID = nil } }
            )
        ) {
            if let id = viewerPhotoID {
                PhotoViewerView(
                    visit: visit,
                    photoIDs: visit.photos.map(\.localIdentifier),
                    selection: id
                )
            }
        }
        .onChange(of: visit.occasion) { _, _ in try? modelContext.save() }
        .onChange(of: visit.userNote) { _, _ in try? modelContext.save() }
        .onDisappear { player.stop() }
        .task {
            dishRecognizer.recognize(visit.photos.map(\.localIdentifier))
            Analytics.log("visit_viewed", [
                "brand": LoyaltyDirectory.program(for: visit.restaurant?.name)?.brand ?? "Independent"
            ])
        }
    }

    @ViewBuilder
    private func ratingButton(_ rating: VisitRating) -> some View {
        let selected = visit.rating == rating
        Button {
            visit.rating = selected ? nil : rating // tap again to clear
            try? modelContext.save()
            if !selected { Analytics.log("rating_set", ["rating": rating.rawValue]) }
        } label: {
            VStack(spacing: 4) {
                Text(rating.emoji).font(.title)
                Text(rating.label).font(.caption).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .grayscale(selected ? 0 : 0.4)
            .opacity(selected || visit.rating == nil ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func deleteVoiceNotes(_ offsets: IndexSet) {
        player.stop()
        for index in offsets {
            let note = visit.voiceNotes[index]
            try? FileManager.default.removeItem(at: note.audioURL)
            modelContext.delete(note)
        }
        try? modelContext.save()
    }
}
