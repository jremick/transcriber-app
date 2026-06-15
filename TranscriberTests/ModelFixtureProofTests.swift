import Foundation
import Testing
@testable import Transcriber

private enum ModelFixtureConfig {
    static let runFlag = "TRANSCRIBER_RUN_MODEL_FIXTURE_TESTS"
    static let runFluidAudioFlag = "TRANSCRIBER_RUN_FLUIDAUDIO_FIXTURE_TESTS"
    static let runLocalASRFlag = "TRANSCRIBER_RUN_LOCAL_ASR_FIXTURE_TESTS"
    static let speechFixtureURLKey = "TRANSCRIBER_MODEL_FIXTURE_SPEECH_URL"
    static let expectedWordKey = "TRANSCRIBER_MODEL_FIXTURE_EXPECTED_WORD"
    static let markerURL = URL(fileURLWithPath: "/tmp/transcriber-model-fixture-proof.env")
    private static let markerMaxAge: TimeInterval = 30 * 60

    static var isEnabled: Bool {
        value(for: runFlag) == "1"
    }

    static var isFluidAudioEnabled: Bool {
        isEnabled || value(for: runFluidAudioFlag) == "1"
    }

    static var isLocalASREnabled: Bool {
        isEnabled || value(for: runLocalASRFlag) == "1"
    }

    static func value(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? markerValues()[key]
    }

    private static func markerValues() -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: markerURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) <= markerMaxAge,
              let contents = try? String(contentsOf: markerURL, encoding: .utf8)
        else {
            return [:]
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                guard let separator = line.firstIndex(of: "=") else { return }
                let key = line[..<separator]
                let value = line[line.index(after: separator)...]
                result[String(key)] = String(value)
            }
    }
}

private enum ModelFixtureError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let operation):
            "Timed out while waiting for \(operation)."
        }
    }
}

@MainActor
struct ModelFixtureProofTests {
    @Test(.enabled(
        if: ModelFixtureConfig.isLocalASREnabled,
        "Set TRANSCRIBER_RUN_LOCAL_ASR_FIXTURE_TESTS=1 to run local ASR fixture proof."
    ))
    func localSpeechTranscriberConsumesSpeechFixture() async throws {
        let url = try speechFixtureURL()
        let chunks = try AudioFixture.chunks(from: url, chunkDuration: 0.4)
        #expect(!chunks.isEmpty)

        let engine = LocalSpeechEngine()
        do {
            try await engine.prepare(locale: Locale(identifier: "en_US")) { _ in }
            let events = try await engine.start(
                micStream: AudioFixture.stream(from: []),
                systemStream: AudioFixture.stream(from: chunks)
            )
            let stopDelay = max(8, Int(ceil(chunks.totalDuration)) + 2)
            let stopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(stopDelay))
                await engine.stop()
            }
            defer { stopTask.cancel() }
            let collected = try await collectEngineEvents(events, timeout: .seconds(60))
            await engine.stop()

            let finalSystemSegments = collected.compactMap { event -> TranscriptSegment? in
                guard case .final(let segment) = event, segment.source == .system else {
                    return nil
                }
                return segment
            }
            let finalText = finalSystemSegments
                .map(\.text)
                .joined(separator: " ")
                .lowercased()
            let expectedWord = ModelFixtureConfig.value(for: ModelFixtureConfig.expectedWordKey)
                ?? "quarterly"

            #expect(!finalSystemSegments.isEmpty)
            #expect(finalText.contains(expectedWord.lowercased()))
        } catch {
            await engine.stop()
            throw error
        }
    }

    @Test(.enabled(
        if: ModelFixtureConfig.isFluidAudioEnabled,
        "Set TRANSCRIBER_RUN_FLUIDAUDIO_FIXTURE_TESTS=1 to run FluidAudio fixture proof."
    ))
    func fluidAudioDiarizerConsumesSpeechFixture() async throws {
        let url = try speechFixtureURL()
        let chunks = try AudioFixture.chunks(from: url, chunkDuration: 0.2)
        let fixtureDuration = chunks.totalDuration
        #expect(!chunks.isEmpty)
        #expect(fixtureDuration > 1)

        let service = DiarizationService()
        try await service.prepare()
        let intervalStream = await service.run(stream: AudioFixture.stream(from: chunks))
        let intervals = try await collectIntervals(intervalStream, timeout: .seconds(60))
        await service.stop()

        let state = await service.debugStateForTests()
        #expect(state.processingAttemptCount > 0)
        #expect(state.processingErrorCount == 0, "Last error: \(state.lastProcessingErrorDescription ?? "none")")
        #expect(abs(state.totalFedSeconds - fixtureDuration) < 0.25)
        #expect(intervals.allSatisfy { $0.end >= $0.start })
    }

    private func speechFixtureURL() throws -> URL {
        let path = try #require(
            ModelFixtureConfig.value(for: ModelFixtureConfig.speechFixtureURLKey),
            "Set \(ModelFixtureConfig.speechFixtureURLKey) to a local speech WAV or AIFF fixture."
        )
        let url = URL(fileURLWithPath: path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        return url
    }
}

private func collectEngineEvents(
    _ stream: AsyncThrowingStream<EngineEvent, Error>,
    timeout: Duration
) async throws -> [EngineEvent] {
    try await withThrowingTaskGroup(of: [EngineEvent].self) { group in
        group.addTask {
            var events: [EngineEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ModelFixtureError.timeout("SpeechTranscriber fixture results")
        }

        let events = try await group.next() ?? []
        group.cancelAll()
        return events
    }
}

private func collectIntervals(
    _ stream: AsyncStream<SpeakerInterval>,
    timeout: Duration
) async throws -> [SpeakerInterval] {
    try await withThrowingTaskGroup(of: [SpeakerInterval].self) { group in
        group.addTask {
            var intervals: [SpeakerInterval] = []
            for await interval in stream {
                intervals.append(interval)
            }
            return intervals
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ModelFixtureError.timeout("FluidAudio diarization fixture intervals")
        }

        let intervals = try await group.next() ?? []
        group.cancelAll()
        return intervals
    }
}

private extension [AudioChunk] {
    var totalDuration: TimeInterval {
        reduce(0) { $0 + $1.duration }
    }
}
