import SwiftUI
import SwiftData

struct AskJournalView: View {
    @Query(sort: [SortDescriptor(\Visit.date, order: .reverse)])
    private var visits: [Visit]

    @AppStorage(LLMProvider.defaultsKey) private var providerRaw = LLMProvider.claude.rawValue
    @AppStorage("askAutoSpeak") private var autoSpeak = true

    @StateObject private var dictation = SpeechDictationService()
    @StateObject private var speaker = AnswerSpeaker()

    @State private var question = ""
    @State private var answer = ""
    @State private var referencedVisits: [Visit] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showingSettings = false

    private var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .claude }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                answerArea
                Divider()
                voiceBar
            }
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    Button {
                        autoSpeak.toggle()
                        if !autoSpeak { speaker.stop() }
                    } label: {
                        Image(systemName: autoSpeak ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Model", selection: $providerRaw) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Answer area

    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if answer.isEmpty && !isLoading && question.isEmpty && !dictation.isListening {
                    emptyState
                }

                if !question.isEmpty {
                    Text(question)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                }

                if !answer.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Text(answer)
                        Spacer(minLength: 0)
                        Button {
                            if speaker.isSpeaking { speaker.stop() } else { speaker.speak(answer) }
                        } label: {
                            Image(systemName: speaker.isSpeaking ? "stop.circle.fill" : "play.circle")
                                .font(.title3)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if !referencedVisits.isEmpty {
                    Text("Referenced visits").font(.headline)
                    ForEach(referencedVisits) { visit in
                        referencedRow(visit)
                    }
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Tap the mic and ask about your visits.")
                .foregroundStyle(.secondary)
            Text("“Where did we get those tacos after the game?”")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Text("Fair-use limit: up to \(QueryRateLimiter.perMinute)/min and \(QueryRateLimiter.perHour)/hour.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func referencedRow(_ visit: Visit) -> some View {
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

    // MARK: - Voice bar

    private var voiceBar: some View {
        VStack(spacing: 10) {
            if dictation.isListening {
                Text(dictation.transcript.isEmpty ? "Listening…" : dictation.transcript)
                    .font(.callout)
                    .foregroundStyle(dictation.transcript.isEmpty ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                TextField("Or type a question", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)

                Button {
                    Task { await ask() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

                Button(action: toggleMic) {
                    Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(dictation.isListening ? Color.red : Color.accentColor)
                        .clipShape(Circle())
                        .symbolEffect(.pulse, isActive: dictation.isListening)
                }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func toggleMic() {
        if dictation.isListening {
            dictation.stop()
            let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                question = spoken
                Task { await ask() }
            }
        } else {
            speaker.stop()
            errorText = nil
            answer = ""
            referencedVisits = []
            question = ""
            Task {
                let granted = await dictation.requestPermission()
                guard granted else {
                    errorText = "Microphone and Speech permission are required to ask by voice."
                    return
                }
                do {
                    try dictation.start()
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func ask() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = provider.makeClient() else {
            errorText = "No \(provider.displayName) API key. Tap the gear to add one."
            return
        }
        // Client-side throttle — stop spamming before it ever reaches the server.
        if let limitMessage = QueryRateLimiter.blockMessage() {
            errorText = limitMessage
            return
        }
        question = trimmed
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        QueryRateLimiter.record()
        let service = JournalQueryService(client: client)
        do {
            let result = try await service.ask(question: trimmed, visits: visits)
            answer = result.answer
            referencedVisits = result.referencedVisitIDs.compactMap { id in
                visits.first { $0.persistentModelID == id }
            }
            if autoSpeak { speaker.speak(answer) }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
