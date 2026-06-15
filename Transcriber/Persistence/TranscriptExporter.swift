import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptExporter {
    static func markdown(for session: MeetingSession) -> String {
        let speakerByKey = Dictionary(
            uniqueKeysWithValues: session.speakers.map { ($0.key, $0.name) })
        let date = session.startedAt.formatted(date: .long, time: .shortened)

        var lines: [String] = [
            "# \(session.title)",
            "",
            "- **Date:** \(date)",
            "- **Duration:** \(FormatStyle.clock(session.duration))",
        ]
        if let app = session.sourceAppName {
            lines.append("- **App:** \(app)")
        }

        if !session.notesMarkdown.isEmpty {
            lines += ["", "## Key Notes", "", session.notesMarkdown]
        }

        lines += ["", "## Transcript", ""]
        for segment in session.segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            let name = speakerByKey[segment.speakerKey] ?? segment.speakerKey
            lines.append("**\(name)** [\(FormatStyle.clock(segment.startOffset))]: \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    @discardableResult
    static func exportWithPanel(session: MeetingSession) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName(for: session)
        panel.title = "Export Transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try writeMarkdown(for: session, to: url)
        return url
    }

    static func writeMarkdown(for session: MeetingSession, to url: URL) throws {
        try markdown(for: session).write(to: url, atomically: true, encoding: .utf8)
    }

    static func suggestedFileName(for session: MeetingSession) -> String {
        let stamp = session.startedAt.formatted(
            .iso8601.year().month().day().dateSeparator(.dash))
        let safeTitle = session.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(stamp) \(safeTitle).md"
    }
}
