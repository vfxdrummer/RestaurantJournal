import SwiftUI
import SwiftData
import UIKit

/// Builds a personalized, shareable recommendation for a place the user has visited: an editable
/// blurb (grounded in their own notes via Claude), a curated selection of their photos, and a
/// Google Maps link — sent out through the native share sheet.
struct ShareRecommendationView: View {
    let visit: Visit
    @Environment(\.dismiss) private var dismiss

    @State private var blurb = ""
    @State private var recipientNote = ""
    @State private var isGenerating = false
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var isPreparingShare = false
    @State private var shareItems: [Any] = []
    @State private var showingShareSheet = false

    private var restaurant: Restaurant? { visit.restaurant }
    private var placeName: String { restaurant?.name ?? "this place" }

    /// All of the user's visits to this establishment — grounds the blurb and gathers photos.
    private var placeVisits: [Visit] {
        if let restaurant {
            return restaurant.visits.sorted { $0.date > $1.date }
        }
        return [visit]
    }

    /// Deduplicated photo identifiers across every visit to this place.
    private var photoIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for placeVisit in placeVisits {
            for photo in placeVisit.photos where seen.insert(photo.localIdentifier).inserted {
                ids.append(photo.localIdentifier)
            }
        }
        return ids
    }

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Recommendation") {
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Writing…").foregroundStyle(.secondary)
                        }
                    }
                    TextEditor(text: $blurb)
                        .frame(minHeight: 110)
                }

                Section {
                    TextField("Who's it for? e.g. Priya, visiting, loves spicy food", text: $recipientNote, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        Task { await generate() }
                    } label: {
                        Label("Rewrite", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isGenerating)
                } header: {
                    Text("Personalize (optional)")
                } footer: {
                    if !hasAPIKey {
                        Text("Set ANTHROPIC_API_KEY in the scheme to personalize with AI. Using a simple template for now.")
                    }
                }

                if !photoIDs.isEmpty {
                    Section("Photos — \(selectedPhotoIDs.count) selected") {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(photoIDs, id: \.self) { id in
                                selectablePhoto(id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let url = restaurant?.googleMapsURL {
                    Section("Link") {
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .navigationTitle("Recommend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await prepareAndShare() }
                    } label: {
                        if isPreparingShare { ProgressView() } else { Text("Share") }
                    }
                    .disabled(isPreparingShare || blurb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                selectedPhotoIDs = Set(photoIDs.prefix(6))
                await generate()
            }
            .sheet(isPresented: $showingShareSheet) {
                ActivityView(items: shareItems) { showingShareSheet = false }
            }
        }
    }

    // MARK: - Photo cell

    @ViewBuilder
    private func selectablePhoto(_ id: String) -> some View {
        let isSelected = selectedPhotoIDs.contains(id)
        PhotoThumbnailView(localIdentifier: id, targetSize: CGSize(width: 180, height: 180))
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.3)))
                    .padding(4)
            }
            .opacity(isSelected ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                if isSelected { selectedPhotoIDs.remove(id) } else { selectedPhotoIDs.insert(id) }
            }
    }

    // MARK: - Actions

    private var hasAPIKey: Bool { ClaudeClient.fromEnvironment() != nil }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        if let text = await RecommendationService.generateBlurb(
            placeName: placeName,
            address: restaurant?.address,
            visits: placeVisits,
            recipientNote: recipientNote
        ) {
            blurb = text
        } else if blurb.isEmpty {
            blurb = RecommendationService.fallbackBlurb(placeName: placeName, visits: placeVisits)
        }
    }

    private func prepareAndShare() async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        var items: [Any] = [blurb.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let url = restaurant?.googleMapsURL {
            items.append(url)
        }
        // Load selected photos at share quality, preserving grid order.
        for id in photoIDs where selectedPhotoIDs.contains(id) {
            if let image = await PhotoThumbnailLoader.loadShareImage(localIdentifier: id) {
                items.append(image)
            }
        }
        shareItems = items
        showingShareSheet = true
    }
}
