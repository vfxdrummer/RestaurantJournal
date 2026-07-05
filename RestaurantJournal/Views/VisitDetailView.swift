import SwiftUI
import SwiftData

struct VisitDetailView: View {
    @Bindable var visit: Visit
    @Environment(\.modelContext) private var modelContext

    @State private var showingRecorder = false
    @State private var showingEditPlace = false
    @State private var showingShare = false

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        Form {
            Section("Place") {
                if let r = visit.restaurant {
                    RestaurantNameLabel(restaurant: r, logoSize: 24)
                    if let addr = r.address { Text(addr).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Unknown restaurant").foregroundStyle(.secondary)
                }
                Text(visit.date.formatted(date: .complete, time: .shortened))
                    .font(.caption)

                Button {
                    showingEditPlace = true
                } label: {
                    Label(visit.restaurant == nil ? "Set place" : "Wrong place? Change it",
                          systemImage: "mappin.and.ellipse")
                }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.transcript ?? "(no transcript)")
                            .font(.body)
                        Text(note.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
                            PhotoThumbnailView(
                                localIdentifier: photo.localIdentifier,
                                targetSize: CGSize(width: 300, height: 300)
                            )
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .navigationTitle(visit.restaurant?.name ?? "Visit")
        .navigationBarTitleDisplayMode(.inline)
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
        .onChange(of: visit.occasion) { _, _ in try? modelContext.save() }
        .onChange(of: visit.userNote) { _, _ in try? modelContext.save() }
    }
}
