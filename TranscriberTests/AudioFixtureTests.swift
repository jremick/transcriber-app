import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Transcriber

@MainActor
struct AudioFixtureTests {
    @Test func wavFixtureLoadsIntoDeterministicChunks() throws {
        let url = try writeWAV(frameCount: 1_600, sampleRate: 16_000, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try AudioFixture.chunks(from: url, chunkDuration: 0.025)
        let totalDuration = chunks.reduce(0) { $0 + $1.duration }

        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.format.sampleRate == 16_000 })
        #expect(chunks.allSatisfy { $0.format.channelCount == 1 })
        #expect(chunks.map(\.frameCount) == [400, 400, 400, 400])
        #expect(abs(totalDuration - 0.1) < 0.001)
        #expect((chunks.first?.rmsLevel ?? 0) > 0)
    }

    @Test func wavFixtureChunksDriveAttributionPersistenceAndExport() throws {
        let micURL = try writeWAV(frameCount: 800, sampleRate: 16_000, amplitude: 0.1)
        let systemURL = try writeWAV(frameCount: 1_600, sampleRate: 16_000, amplitude: 0.2)
        defer {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        }

        let micChunks = try AudioFixture.chunks(from: micURL, chunkDuration: 0.025)
        let systemChunks = try AudioFixture.chunks(from: systemURL, chunkDuration: 0.05)
        let micDuration = micChunks.totalDuration
        let systemDuration = systemChunks.totalDuration
        let remoteStart: TimeInterval = 6

        var pipeline = TranscriptPipeline()
        let localSegment = TranscriptSegment(
            id: fixedID("201"),
            source: .microphone,
            speaker: .you,
            text: "I will cover the launch agenda.",
            start: 0,
            end: micDuration,
            isFinal: true
        )
        let remoteSegment = TranscriptSegment(
            id: fixedID("202"),
            source: .system,
            speaker: .unattributed,
            text: "Quarterly metrics moved upward.",
            start: remoteStart,
            end: remoteStart + systemDuration,
            isFinal: true
        )

        pipeline.apply(.final(localSegment))
        pipeline.apply(.final(remoteSegment))
        pipeline.applyInterval(SpeakerInterval(
            clusterIndex: 0,
            start: remoteStart,
            end: remoteStart + systemDuration
        ))
        pipeline.flushAllAttributions()
        pipeline.renameSpeaker(.remote(0), to: "Fixture Speaker")

        #expect(pipeline.segments.map(\.speaker) == [.you, .remote(0)])

        let container = PersistenceController.makeContainer(inMemory: true)
        let recorder = SessionRecorder(container: container)
        let fixtureSegments = pipeline.segments
        let fixtureSpeakers = pipeline.speakers
        recorder.snapshotProvider = {
            SessionRecorder.Snapshot(
                title: "WAV Fixture",
                notesMarkdown: "- WAV fixture path exercised.",
                notesPrompt: "Summarize fixture.",
                segments: fixtureSegments,
                speakers: fixtureSpeakers
            )
        }

        try recorder.begin(title: "Draft", sourceApp: "WAV Fixture", engine: "fixture")
        let id = try recorder.finish(duration: remoteStart + systemDuration)

        #expect(id != nil)
        let session = try #require(container.mainContext.fetch(FetchDescriptor<MeetingSession>()).first)
        let markdown = TranscriptExporter.markdown(for: session)

        #expect(session.segments.count == 2)
        #expect(session.segments.contains { $0.source == AudioSource.microphone.rawValue })
        #expect(session.segments.contains { $0.source == AudioSource.system.rawValue })
        #expect(markdown.contains("**You** [00:00]: I will cover the launch agenda."))
        #expect(markdown.contains("**Fixture Speaker** [00:06]: Quarterly metrics moved upward."))
    }

    @Test func audioFixtureStreamYieldsLoadedChunksInOrder() async throws {
        let url = try writeWAV(frameCount: 800, sampleRate: 16_000, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunks = try AudioFixture.chunks(from: url, chunkDuration: 0.025)

        var frameCounts: [AVAudioFrameCount] = []
        for await chunk in AudioFixture.stream(from: chunks) {
            frameCounts.append(chunk.frameCount)
        }

        #expect(frameCounts == [400, 400])
    }

    private func writeWAV(
        frameCount: AVAudioFrameCount,
        sampleRate: Double,
        amplitude: Float
    ) throws -> URL {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = amplitude * sin(Float(frame) * 0.03)
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcriber-audio-fixture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func fixedID(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!
    }
}

private extension [AudioChunk] {
    var totalDuration: TimeInterval {
        reduce(0) { $0 + $1.duration }
    }
}
