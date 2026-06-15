import Foundation
import SwiftData
import Testing
@testable import Transcriber

@MainActor
struct ExporterTests {
    @Test func markdownContainsNotesTranscriptAndSpeakers() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext

        let session = MeetingSession(title: "Roadmap Sync", sourceAppName: "Zoom")
        session.duration = 125
        session.notesMarkdown = "- Decided to ship v1"
        context.insert(session)

        let you = SpeakerRecord(key: "you", name: "Taylor", colorIndex: 0)
        you.session = session
        let remote = SpeakerRecord(key: "spk-0", name: "Alex", colorIndex: 1)
        remote.session = session
        context.insert(you)
        context.insert(remote)

        let first = TranscriptSegmentRecord(segment: TranscriptSegment(
            source: .system, speaker: .remote(0), text: "Shall we ship?",
            start: 10, end: 12, isFinal: true))
        first.session = session
        let second = TranscriptSegmentRecord(segment: TranscriptSegment(
            source: .microphone, speaker: .you, text: "Yes, next week.",
            start: 13, end: 15, isFinal: true))
        second.session = session
        context.insert(first)
        context.insert(second)
        try context.save()

        let markdown = TranscriptExporter.markdown(for: session)
        #expect(markdown.contains("# Roadmap Sync"))
        #expect(markdown.contains("**Duration:** 02:05"))
        #expect(markdown.contains("## Key Notes"))
        #expect(markdown.contains("- Decided to ship v1"))
        #expect(markdown.contains("**Alex** [00:10]: Shall we ship?"))
        #expect(markdown.contains("**Taylor** [00:13]: Yes, next week."))
        // Transcript ordered by time.
        let alexIndex = markdown.range(of: "**Alex**")!.lowerBound
        let taylorIndex = markdown.range(of: "**Taylor**")!.lowerBound
        #expect(alexIndex < taylorIndex)
    }

    @Test func fileNameIsSafe() {
        let session = MeetingSession(title: "Q3: budget / planning?")
        let name = TranscriptExporter.suggestedFileName(for: session)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("?"))
        #expect(name.hasSuffix(".md"))
    }

    @Test func writeMarkdownCreatesFile() throws {
        let session = MeetingSession(title: "Export Proof")
        session.duration = 65
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcriber-export-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try TranscriptExporter.writeMarkdown(for: session, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("# Export Proof"))
        #expect(content.contains("**Duration:** 01:05"))
    }

    @Test func writeMarkdownPropagatesWriteFailure() throws {
        let session = MeetingSession(title: "Export Failure")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcriber-export-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var didThrow = false
        do {
            try TranscriptExporter.writeMarkdown(for: session, to: directory)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }
}
