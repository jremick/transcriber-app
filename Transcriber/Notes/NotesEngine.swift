import Foundation
import FoundationModels

/// Incrementally maintains meeting notes: takes the notes so far plus new
/// transcript lines, returns the updated notes (Markdown).
protocol NotesEngine: Sendable {
    func updateNotes(existing: String, newTranscript: String, instructions: String) async throws -> String
}

enum NotesError: LocalizedError {
    case unavailable(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .generationFailed(let reason): "Notes update failed: \(reason)"
        }
    }
}

/// On-device notes via Apple Foundation Models (requires Apple Intelligence).
/// Sessions are created per-update — state lives in the notes text itself, so
/// the ~4k-token context window only ever sees notes + the newest transcript.
struct FoundationModelsNotesEngine: NotesEngine {
    static func availabilityIssue() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence. Use Automatic or Local extractive notes, or add an OpenAI key."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings, use Local extractive notes, or add an OpenAI key."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Notes will start once it's ready."
        case .unavailable(let other):
            return "On-device notes unavailable (\(String(describing: other)))."
        }
    }

    func updateNotes(
        existing: String, newTranscript: String, instructions: String
    ) async throws -> String {
        if let issue = Self.availabilityIssue() {
            throw NotesError.unavailable(issue)
        }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Notes so far:
        \(existing.isEmpty ? "(none yet — this is the start of the meeting)" : existing)

        New transcript portion:
        \(newTranscript)

        Updated notes:
        """
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? existing : text
        } catch {
            throw NotesError.generationFailed(error.localizedDescription)
        }
    }
}

/// Deterministic local fallback that extracts speaker-labeled transcript lines
/// into compact Markdown bullets. It is not a generative summary, but it keeps
/// v1 notes local and available when Apple Intelligence and OpenAI are absent.
struct LocalExtractiveNotesEngine: NotesEngine {
    private let maxBullets = 10

    func updateNotes(
        existing: String, newTranscript: String, instructions: String
    ) async throws -> String {
        let existingBullets = Self.bullets(from: existing)
        let newBullets = Self.candidateBullets(from: newTranscript)
        let merged = Self.merge(existing: existingBullets, new: newBullets, limit: maxBullets)
        return merged.isEmpty ? existing : merged.joined(separator: "\n")
    }

    private static func bullets(from markdown: String) -> [String] {
        markdown
            .split(whereSeparator: \.isNewline)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return "" }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    private static func candidateBullets(from transcript: String) -> [String] {
        let sentences = transcript
            .split(whereSeparator: \.isNewline)
            .flatMap { line -> [String] in
                let text = stripSpeakerLabel(String(line))
                return text
                    .components(separatedBy: sentenceSeparators)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter(isUsefulSentence)

        let prioritized = sentences.sorted { score($0) > score($1) }
        return prioritized.prefix(6).map { "- \($0)" }
    }

    private static let sentenceSeparators = CharacterSet(charactersIn: ".!?")

    private static func stripSpeakerLabel(_ line: String) -> String {
        guard let separator = line.firstIndex(of: ":") else {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = line[..<separator]
        guard prefix.count <= 32 else {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsefulSentence(_ sentence: String) -> Bool {
        let wordCount = sentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        return wordCount >= 4 && sentence.count <= 220
    }

    private static func score(_ sentence: String) -> Int {
        let lowered = sentence.lowercased()
        let keywords = [
            "action", "owner", "follow up", "next", "need", "deadline", "by ",
            "decide", "decision", "agreed", "risk", "blocked", "issue", "launch",
            "budget", "review", "ship", "meeting", "plan", "customer",
        ]
        return keywords.reduce(0) { total, keyword in
            lowered.contains(keyword) ? total + 1 : total
        }
    }

    private static func merge(existing: [String], new: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for bullet in existing + new {
            let key = bullet
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            merged.append(bullet)
        }
        return Array(merged.suffix(limit))
    }
}
