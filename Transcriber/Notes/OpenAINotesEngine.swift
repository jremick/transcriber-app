import Foundation

/// Cloud notes via the OpenAI Responses API.
struct OpenAINotesEngine: NotesEngine {
    let apiKey: String
    let model: String

    func updateNotes(
        existing: String, newTranscript: String, instructions: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let input = """
        Notes so far:
        \(existing.isEmpty ? "(none yet — this is the start of the meeting)" : existing)

        New transcript portion:
        \(newTranscript)

        Updated notes:
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestPayload(
            model: model,
            input: input,
            instructions: instructions
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotesError.generationFailed("No response from OpenAI")
        }
        guard http.statusCode == 200 else {
            let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw NotesError.generationFailed(detail)
        }

        guard let text = Self.outputText(from: data), !text.isEmpty else {
            throw NotesError.generationFailed("Empty response")
        }
        return text
    }

    static func requestPayload(
        model: String,
        input: String,
        instructions: String
    ) -> [String: Any] {
        [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
        ]
    }

    static func outputText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]]
        else { return nil }
        var pieces: [String] = []
        for item in output where (item["type"] as? String) == "message" {
            for content in (item["content"] as? [[String: Any]]) ?? []
            where (content["type"] as? String) == "output_text" {
                if let text = content["text"] as? String {
                    pieces.append(text)
                }
            }
        }
        let joined = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}
