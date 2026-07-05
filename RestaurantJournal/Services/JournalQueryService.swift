import Foundation
import SwiftData

/// Sends structured visit data + a natural-language question to the Claude API.
/// This is a straight structured-context approach (no vector DB) — appropriate at MVP scale.
@MainActor
final class JournalQueryService {
    // TODO: Move to Keychain in production. For MVP dev, set here or via env.
    private let apiKey: String
    private let modelName: String

    init(apiKey: String, modelName: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.modelName = modelName
    }

    struct QueryResult {
        let answer: String
        /// Persistent IDs of visits the model referenced, so the UI can surface them.
        let referencedVisitIDs: [PersistentIdentifier]
    }

    func ask(question: String, visits: [Visit]) async throws -> QueryResult {
        let context = buildVisitContext(visits: visits)
        let system = """
        You are a helpful assistant answering questions about the user's food journal.
        You will be given a JSON array of the user's restaurant visits.
        Answer their question concisely and reference specific visits by their `id` field when relevant.
        If you reference visits, include a final line in the format: `REFERENCED_IDS: [id1, id2]`
        If you don't know or the data doesn't contain the answer, say so plainly.
        """

        let userMessage = """
        Here is my food journal:
        ```json
        \(context.json)
        ```

        Question: \(question)
        """

        let answerText = try await callClaude(system: system, user: userMessage)

        // Parse referenced IDs
        let idIntegers = parseReferencedIDs(from: answerText)
        let cleanAnswer = answerText
            .replacingOccurrences(of: #"REFERENCED_IDS:\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let referencedVisits = idIntegers.compactMap { context.idMap[$0] }
        return QueryResult(answer: cleanAnswer, referencedVisitIDs: referencedVisits)
    }

    // MARK: - Context building

    private struct VisitContextPayload {
        let json: String
        let idMap: [Int: PersistentIdentifier]  // integer id → SwiftData persistent id
    }

    private func buildVisitContext(visits: [Visit]) -> VisitContextPayload {
        var idMap: [Int: PersistentIdentifier] = [:]
        var records: [[String: Any]] = []

        for (index, visit) in visits.enumerated() {
            let integerID = index + 1
            idMap[integerID] = visit.persistentModelID

            var record: [String: Any] = [
                "id": integerID,
                "date": ISO8601DateFormatter().string(from: visit.date)
            ]
            if let r = visit.restaurant {
                record["restaurant"] = r.name
                if let addr = r.address { record["address"] = addr }
            }
            if let occ = visit.occasion, !occ.isEmpty { record["occasion"] = occ }
            if let note = visit.userNote, !note.isEmpty { record["note"] = note }
            let transcripts = visit.voiceNotes.compactMap { $0.transcript }
            if !transcripts.isEmpty { record["voice_notes"] = transcripts }
            records.append(record)
        }

        let data = (try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted])) ?? Data()
        return VisitContextPayload(
            json: String(data: data, encoding: .utf8) ?? "[]",
            idMap: idMap
        )
    }

    private func parseReferencedIDs(from text: String) -> [Int] {
        guard let range = text.range(of: #"REFERENCED_IDS:\s*\[([^\]]*)\]"#, options: .regularExpression) else {
            return []
        }
        let match = String(text[range])
        let inner = match
            .replacingOccurrences(of: "REFERENCED_IDS:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
        return inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Claude API call

    private func callClaude(system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 1024,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw NSError(domain: "JournalQueryService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        struct APIResponse: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        return decoded.content.compactMap { $0.text }.joined(separator: "\n")
    }
}
