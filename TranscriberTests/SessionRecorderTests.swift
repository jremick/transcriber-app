import Foundation
import SwiftData
import Testing
@testable import Transcriber

@MainActor
struct SessionRecorderTests {
    @Test func emptySessionIsDiscardedOnFinish() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        let recorder = SessionRecorder(container: container)
        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "Empty",
                notesMarkdown: "",
                notesPrompt: "",
                segments: [],
                speakers: [:]
            )
        }

        try recorder.begin(title: "Empty", sourceApp: nil, engine: "local")
        let id = try recorder.finish(duration: 5)

        #expect(id == nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<MeetingSession>())
        #expect(sessions.isEmpty)
    }

    @Test func finishPersistsFinalSnapshot() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        let recorder = SessionRecorder(container: container)
        let segment = TranscriptSegment(
            source: .microphone,
            speaker: .you,
            text: "Let's ship this.",
            start: 1,
            end: 3,
            isFinal: true
        )
        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "Launch Sync",
                notesMarkdown: "- Ship v1",
                notesPrompt: "Track decisions.",
                segments: [segment],
                speakers: [.you: SpeakerInfo(speakerID: .you, name: "Taylor", colorIndex: 0)]
            )
        }

        try recorder.begin(title: "Draft", sourceApp: "Zoom", engine: "local")
        let id = try recorder.finish(duration: 42)

        #expect(id != nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<MeetingSession>())
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.title == "Launch Sync")
        #expect(session.notesMarkdown == "- Ship v1")
        #expect(session.notesPromptUsed == "Track decisions.")
        #expect(session.duration == 42)
        #expect(session.endedAt != nil)
        #expect(session.segments.count == 1)
        #expect(session.segments.first?.text == "Let's ship this.")
        #expect(session.speakers.count == 1)
        #expect(session.speakers.first?.name == "Taylor")
    }

    @Test func finalSaveFailureIsThrown() throws {
        struct SaveFailure: Error {}

        let container = PersistenceController.makeContainer(inMemory: true)
        var saveCount = 0
        let recorder = SessionRecorder(container: container) {
            saveCount += 1
            if saveCount >= 2 {
                throw SaveFailure()
            }
            try container.mainContext.save()
        }
        let segment = TranscriptSegment(
            source: .microphone,
            speaker: .you,
            text: "Persist me.",
            start: 0,
            end: 1,
            isFinal: true
        )
        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "Save Failure",
                notesMarkdown: "",
                notesPrompt: "",
                segments: [segment],
                speakers: [.you: SpeakerInfo(speakerID: .you, name: "You", colorIndex: 0)]
            )
        }

        try recorder.begin(title: "Save Failure", sourceApp: nil, engine: "local")
        var didThrow = false
        do {
            _ = try recorder.finish(duration: 1)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test func repairUnfinishedSessionsClosesNonEmptyAndDeletesEmpty() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext

        let empty = MeetingSession(title: "Empty Crash")
        context.insert(empty)

        let nonEmpty = MeetingSession(title: "Recovered Crash")
        context.insert(nonEmpty)
        let segment = TranscriptSegmentRecord(segment: TranscriptSegment(
            source: .system,
            speaker: .remote(0),
            text: "Recover me.",
            start: 2,
            end: 9,
            isFinal: true
        ))
        segment.session = nonEmpty
        context.insert(segment)
        try context.save()

        let summary = try SessionRecorder.repairUnfinishedSessions(in: container)

        #expect(summary.closedSessions == 1)
        #expect(summary.discardedEmptySessions == 1)
        let sessions = try context.fetch(FetchDescriptor<MeetingSession>())
        #expect(sessions.count == 1)
        let recovered = try #require(sessions.first)
        #expect(recovered.title == "Recovered Crash")
        #expect(recovered.duration == 9)
        #expect(recovered.endedAt == recovered.startedAt.addingTimeInterval(9))
    }

    @Test func longSessionSnapshotPersistsAndExportsTwoHourTimeline() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        let recorder = SessionRecorder(container: container)
        let segmentCount = 750
        let interval: TimeInterval = 10
        let duration = TimeInterval(segmentCount) * interval
        let speakerNames: [SpeakerID: SpeakerInfo] = [
            .you: SpeakerInfo(speakerID: .you, name: "Taylor", colorIndex: 0),
            .remote(0): SpeakerInfo(speakerID: .remote(0), name: "Alex", colorIndex: 1),
            .remote(1): SpeakerInfo(speakerID: .remote(1), name: "Morgan", colorIndex: 2),
        ]

        let segments = (0..<segmentCount).map { index in
            let speaker: SpeakerID = switch index % 3 {
            case 0: .you
            case 1: .remote(0)
            default: .remote(1)
            }
            let source: AudioSource = speaker.isYou ? .microphone : .system
            let start = TimeInterval(index) * interval
            let speakerName = speakerNames[speaker]?.name ?? speaker.key
            return TranscriptSegment(
                id: deterministicSegmentID(index),
                source: source,
                speaker: speaker,
                text: "Long session segment \(index + 1) from \(speakerName).",
                start: start,
                end: start + 4,
                isFinal: true
            )
        }

        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "Long Session Fixture",
                notesMarkdown: "- Persistence stayed available across a two-hour fixture.",
                notesPrompt: "Summarize risks and decisions.",
                segments: segments,
                speakers: speakerNames
            )
        }

        try recorder.begin(title: "Draft", sourceApp: "Soak Fixture", engine: "fixture")
        let id = try recorder.finish(duration: duration)

        #expect(id != nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<MeetingSession>())
        let session = try #require(sessions.first)
        let persistedSegments = session.segments.sorted { $0.startOffset < $1.startOffset }
        let sourceCounts = Dictionary(grouping: persistedSegments, by: { $0.source })
            .mapValues { $0.count }
        let markdown = TranscriptExporter.markdown(for: session)

        #expect(session.duration == duration)
        #expect(session.endedAt != nil)
        #expect(persistedSegments.count == segmentCount)
        #expect(session.speakers.count == speakerNames.count)
        #expect(sourceCounts[AudioSource.microphone.rawValue] == 250)
        #expect(sourceCounts[AudioSource.system.rawValue] == 500)
        #expect(persistedSegments.first?.startOffset == 0)
        #expect(persistedSegments.last?.startOffset == 7490)
        #expect(markdown.contains("**Duration:** 2:05:00"))
        #expect(markdown.contains("**Taylor** [00:00]: Long session segment 1 from Taylor."))
        #expect(markdown.contains("**Morgan** [2:04:50]: Long session segment 750 from Morgan."))
        #expect(markdown.range(of: "Long session segment 1")!.lowerBound
            < markdown.range(of: "Long session segment 750")!.lowerBound)
    }

    private func deterministicSegmentID(_ index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!
    }
}
