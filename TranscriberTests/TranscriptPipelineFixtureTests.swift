import Foundation
import SwiftData
import Testing
@testable import Transcriber

@MainActor
struct TranscriptPipelineFixtureTests {
    @Test func resetTimelinePreparesForFallbackWithoutDroppingTranscriptOrSpeakers() throws {
        var pipeline = TranscriptPipeline()

        let preFallback = TranscriptSegment(
            id: fixedID("101"),
            source: .system,
            speaker: .unattributed,
            text: "Casey is reviewing the metrics.",
            start: 0.2,
            end: 1.2,
            isFinal: true
        )
        pipeline.apply(.volatile(source: .system, text: "Partial cloud text"))
        pipeline.apply(.final(preFallback))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 2, start: 0.1, end: 1.3))
        pipeline.flushAllAttributions()
        pipeline.renameSpeaker(.remote(2), to: "Casey")

        pipeline.resetTimeline()

        #expect(pipeline.volatileText.isEmpty)
        #expect(pipeline.segments.map(\.id) == [preFallback.id])
        #expect(pipeline.speakerInfo(for: .remote(2)).name == "Casey")

        let postFallback = TranscriptSegment(
            id: fixedID("102"),
            source: .system,
            speaker: .unattributed,
            text: "The local engine restarted cleanly.",
            start: 0.2,
            end: 1.0,
            isFinal: true
        )
        pipeline.apply(.final(postFallback))
        pipeline.flushAllAttributions()

        #expect(pipeline.segments.map(\.speaker) == [.remote(2), .remote(0)])
        #expect(pipeline.speakerInfo(for: .remote(2)).name == "Casey")
    }

    @Test func repeatedDiarizerClusterAfterFallbackKeepsRenamedSpeaker() throws {
        var pipeline = TranscriptPipeline()

        let beforeSwitch = TranscriptSegment(
            id: fixedID("111"),
            source: .system,
            speaker: .unattributed,
            text: "Casey owns the launch checklist.",
            start: 5.0,
            end: 6.0,
            isFinal: true
        )
        pipeline.apply(.final(beforeSwitch))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 3, start: 4.9, end: 6.1))
        pipeline.flushAllAttributions()
        pipeline.renameSpeaker(.remote(3), to: "Casey")

        pipeline.resetTimeline()

        let afterSwitch = TranscriptSegment(
            id: fixedID("112"),
            source: .system,
            speaker: .unattributed,
            text: "I can keep the same owner.",
            start: 0.2,
            end: 1.0,
            isFinal: true
        )
        pipeline.apply(.final(afterSwitch))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 3, start: 0.1, end: 1.1))
        pipeline.flushAllAttributions()

        #expect(pipeline.segments.map(\.speaker) == [.remote(3), .remote(3)])
        #expect(pipeline.speakerInfo(for: .remote(3)).name == "Casey")
    }

    @Test func resetForNewSessionDropsPreviousTranscriptAndSpeakerState() throws {
        var pipeline = TranscriptPipeline()
        let oldSegment = TranscriptSegment(
            id: fixedID("121"),
            source: .system,
            speaker: .unattributed,
            text: "This belongs to the prior meeting.",
            start: 0,
            end: 1,
            isFinal: true
        )

        pipeline.apply(.volatile(source: .system, text: "Old partial"))
        pipeline.apply(.final(oldSegment))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 1, start: 0, end: 1.1))
        pipeline.flushAllAttributions()
        pipeline.renameSpeaker(.remote(1), to: "Morgan")

        pipeline.resetForNewSession()

        #expect(pipeline.segments.isEmpty)
        #expect(pipeline.turns.isEmpty)
        #expect(pipeline.volatileText.isEmpty)
        #expect(pipeline.speakers == [
            .you: SpeakerInfo(speakerID: .you, name: "You", colorIndex: 0)
        ])
    }

    @Test func fixturePipelinePersistsAndExportsWithoutCaptureDevices() throws {
        var pipeline = TranscriptPipeline()

        pipeline.apply(.volatile(source: .system, text: "The launch checklist"))
        #expect(pipeline.volatileText[.system] == "The launch checklist")
        pipeline.clearVolatileText()
        #expect(pipeline.volatileText.isEmpty)

        let localIntro = TranscriptSegment(
            id: fixedID("001"),
            source: .microphone,
            speaker: .you,
            text: "Let's start with the launch risks.",
            start: 0.5,
            end: 1.8,
            isFinal: true
        )
        let remoteChecklist = TranscriptSegment(
            id: fixedID("002"),
            source: .system,
            speaker: .unattributed,
            text: "The launch checklist has three risks.",
            start: 2.0,
            end: 4.0,
            isFinal: true
        )
        let micEcho = TranscriptSegment(
            id: fixedID("003"),
            source: .microphone,
            speaker: .you,
            text: "The launch checklist has three risks.",
            start: 2.1,
            end: 4.1,
            isFinal: true
        )
        let remoteOwner = TranscriptSegment(
            id: fixedID("004"),
            source: .system,
            speaker: .unattributed,
            text: "Morgan owns the follow-up.",
            start: 7.0,
            end: 9.0,
            isFinal: true
        )

        pipeline.apply(.final(localIntro))
        pipeline.apply(.final(remoteChecklist))
        pipeline.apply(.final(micEcho))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 1, start: 1.9, end: 4.2))
        pipeline.apply(.final(remoteOwner))
        pipeline.applyInterval(SpeakerInterval(clusterIndex: 0, start: 6.8, end: 9.2))
        pipeline.flushAllAttributions()

        #expect(pipeline.segments.map(\.id) == [
            localIntro.id,
            remoteChecklist.id,
            remoteOwner.id,
        ])
        #expect(pipeline.segments.map(\.speaker) == [
            .you,
            .remote(1),
            .remote(0),
        ])
        #expect(pipeline.turns.count == 3)

        pipeline.renameSpeaker(.remote(1), to: "Alex")
        pipeline.renameSpeaker(.remote(0), to: "Morgan")

        let container = PersistenceController.makeContainer(inMemory: true)
        let recorder = SessionRecorder(container: container)
        let fixtureSegments = pipeline.segments
        let fixtureSpeakers = pipeline.speakers
        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "Fixture Sync",
                notesMarkdown: "- Follow up on launch risks.",
                notesPrompt: "Summarize action items.",
                segments: fixtureSegments,
                speakers: fixtureSpeakers
            )
        }

        try recorder.begin(title: "Draft", sourceApp: "Fixture", engine: "fixture")
        let id = try recorder.finish(duration: 12)

        #expect(id != nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<MeetingSession>())
        let session = try #require(sessions.first)
        let persistedSegments = session.segments.sorted { $0.startOffset < $1.startOffset }
        let speakerNames = Dictionary(uniqueKeysWithValues: session.speakers.map { ($0.key, $0.name) })
        let markdown = TranscriptExporter.markdown(for: session)

        #expect(persistedSegments.map(\.text) == [
            "Let's start with the launch risks.",
            "The launch checklist has three risks.",
            "Morgan owns the follow-up.",
        ])
        #expect(speakerNames[SpeakerID.remote(1).key] == "Alex")
        #expect(speakerNames[SpeakerID.remote(0).key] == "Morgan")
        #expect(markdown.contains("**Alex** [00:02]: The launch checklist has three risks."))
        #expect(markdown.contains("**Morgan** [00:07]: Morgan owns the follow-up."))
        #expect(!markdown.contains("**You** [00:02]: The launch checklist has three risks."))
    }

    private func fixedID(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!
    }
}
