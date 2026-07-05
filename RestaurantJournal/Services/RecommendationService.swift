import Foundation

/// Generates a short, personal recommendation blurb for a place the user has visited, grounded in
/// their own occasions, notes, and voice-note transcripts. Optionally tailored to a recipient.
@MainActor
enum RecommendationService {

    static func generateBlurb(placeName: String, address: String?, visits: [Visit], recipientNote: String) async -> String? {
        guard let client = LLMProvider.selected.makeClient() else { return nil }

        let system = """
        You help the user recommend a restaurant they've personally been to, to a friend.
        Write a short (2–4 sentences), warm, genuine recommendation in the FIRST PERSON, in the \
        user's own voice — like texting a friend, not writing a review.
        Ground it ONLY in the details provided (occasions, notes, voice-note transcripts, dishes). \
        Do not invent facts. If a recipient is described, tailor the framing to them.
        Output only the recommendation text, with no preamble or quotation marks.
        """

        let context = buildContext(placeName: placeName, address: address, visits: visits, recipientNote: recipientNote)
        return try? await client.complete(system: system, user: context, maxTokens: 400)
    }

    /// Non-AI fallback used when no API key is configured, so the feature still works.
    static func fallbackBlurb(placeName: String, visits: [Visit]) -> String {
        if let occasion = visits.compactMap({ $0.occasion }).first(where: { !$0.isEmpty }) {
            return "You should check out \(placeName) — we went for \(occasion) and loved it."
        }
        if let note = visits.compactMap({ $0.userNote }).first(where: { !$0.isEmpty }) {
            return "You should check out \(placeName) — \(note)"
        }
        return "You should check out \(placeName) — one of my favorites."
    }

    private static func buildContext(placeName: String, address: String?, visits: [Visit], recipientNote: String) -> String {
        var lines: [String] = ["Place: \(placeName)"]
        if let address { lines.append("Address: \(address)") }

        for (index, visit) in visits.enumerated() {
            var parts: [String] = ["Visit \(index + 1) on \(visit.date.formatted(date: .abbreviated, time: .omitted))"]
            if let occasion = visit.occasion, !occasion.isEmpty { parts.append("occasion: \(occasion)") }
            if let note = visit.userNote, !note.isEmpty { parts.append("note: \(note)") }
            let transcripts = visit.voiceNotes.compactMap { $0.transcript }.filter { !$0.isEmpty }
            if !transcripts.isEmpty { parts.append("what I said: \(transcripts.joined(separator: " "))") }
            lines.append(parts.joined(separator: "; "))
        }

        let recipient = recipientNote.trimmingCharacters(in: .whitespaces)
        if !recipient.isEmpty {
            lines.append("Who/what this recommendation is for: \(recipient)")
        }
        return lines.joined(separator: "\n")
    }
}
