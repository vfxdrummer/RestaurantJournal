import SwiftUI
import SwiftData

struct AskJournalView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Visit.date, order: .reverse)])
    private var visits: [Visit]

    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var referencedVisits: [Visit] = []
    @State private var isLoading = false
    @State private var errorText: String?

    /// TODO: replace with a real key-management approach (Keychain / server relay).
    private var apiKey: String {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Where did we get those tacos after the game?", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    Button {
                        Task { await ask() }
                    } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "paperplane.fill") }
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
                .padding(.horizontal)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !answer.isEmpty {
                            Text(answer)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        if !referencedVisits.isEmpty {
                            Text("Referenced visits")
                                .font(.headline)
                            ForEach(referencedVisits) { visit in
                                NavigationLink(destination: VisitDetailView(visit: visit)) {
                                    HStack {
                                        if let photo = visit.photos.first {
                                            PhotoThumbnailView(
                                                localIdentifier: photo.localIdentifier,
                                                targetSize: CGSize(width: 120, height: 120)
                                            )
                                            .frame(width: 50, height: 50)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        VStack(alignment: .leading) {
                                            RestaurantNameLabel(
                                                restaurant: visit.restaurant,
                                                placeholder: "Unknown",
                                                font: .subheadline.bold(),
                                                logoSize: 18
                                            )
                                            Text(visit.date.formatted(date: .abbreviated, time: .omitted))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding()
                                    .background(Color.gray.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Ask")
        }
    }

    private func ask() async {
        guard !apiKey.isEmpty else {
            errorText = "Set ANTHROPIC_API_KEY in the scheme's environment."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        let service = JournalQueryService(apiKey: apiKey)
        do {
            let result = try await service.ask(question: question, visits: visits)
            answer = result.answer
            // Resolve persistent IDs back to Visit objects
            referencedVisits = result.referencedVisitIDs.compactMap { id in
                visits.first { $0.persistentModelID == id }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
