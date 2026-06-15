import AVFoundation
import Foundation
import os
import Testing
@testable import Transcriber

@MainActor
struct OpenAIRealtimeEngineTests {
    @Test func settingsDefaultUsesRealtimeWhisperModel() {
        let defaults = UserDefaults(suiteName: "OpenAIRealtimeEngineTests")!
        defaults.removePersistentDomain(forName: "OpenAIRealtimeEngineTests")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.openAITranscriptionModel == OpenAIRealtimeEngine.defaultTranscriptionModel)
    }

    @Test func transcriptionSessionPayloadUsesManualCommitCompatibleConfig() throws {
        let json = try OpenAIRealtimeEngine.sessionUpdateJSON(
            model: OpenAIRealtimeEngine.defaultTranscriptionModel)
        let data = try #require(json.data(using: .utf8))
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        let session = try #require(payload["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(payload["type"] as? String == "session.update")
        #expect(session["type"] as? String == "transcription")
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24000)
        #expect(transcription["model"] as? String == OpenAIRealtimeEngine.defaultTranscriptionModel)
        #expect(input["turn_detection"] == nil)
    }

    @Test func deltasAccumulateAndCompletedTranscriptUsesPendingCommitWindow() throws {
        var reducer = OpenAIRealtimeEventReducer(source: .system)
        var pendingTurns: [(start: TimeInterval, end: TimeInterval)] = [(10, 12)]

        let firstDelta = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.delta",
                "item_id": "item-1",
                "delta": "Hello",
            ]),
            baseSeconds: 0,
            sentSeconds: 0,
            pendingTurns: &pendingTurns
        )
        expectVolatile(firstDelta, source: .system, text: "Hello")

        let secondDelta = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.delta",
                "item_id": "item-1",
                "delta": " world",
            ]),
            baseSeconds: 0,
            sentSeconds: 0,
            pendingTurns: &pendingTurns
        )
        expectVolatile(secondDelta, source: .system, text: "Hello world")

        let completed = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "item-1",
                "transcript": " Hello world \n",
            ]),
            baseSeconds: 0,
            sentSeconds: 0,
            pendingTurns: &pendingTurns
        )

        expectVolatileClear(completed, source: .system)
        let segment = try expectFinal(completed, source: .system)
        #expect(segment.speaker == .unattributed)
        #expect(segment.text == "Hello world")
        #expect(segment.start == 10)
        #expect(segment.end == 12)
        #expect(pendingTurns.isEmpty)
    }

    @Test func vadSpeechEventsProvideTurnWindowForCompletedMicTranscript() throws {
        var reducer = OpenAIRealtimeEventReducer(source: .microphone)
        var pendingTurns: [(start: TimeInterval, end: TimeInterval)] = []

        _ = reducer.handle(
            try eventJSON([
                "type": "input_audio_buffer.speech_started",
                "audio_start_ms": 250,
            ]),
            baseSeconds: 4,
            sentSeconds: 3,
            pendingTurns: &pendingTurns
        )
        _ = reducer.handle(
            try eventJSON([
                "type": "input_audio_buffer.speech_stopped",
                "audio_end_ms": 1750,
            ]),
            baseSeconds: 4,
            sentSeconds: 3,
            pendingTurns: &pendingTurns
        )

        #expect(pendingTurns.count == 1)
        #expect(pendingTurns.first?.start == 4.25)
        #expect(pendingTurns.first?.end == 5.75)

        let completed = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "item-2",
                "transcript": "Local reply",
            ]),
            baseSeconds: 4,
            sentSeconds: 3,
            pendingTurns: &pendingTurns
        )

        let segment = try expectFinal(completed, source: .microphone)
        #expect(segment.speaker == .you)
        #expect(segment.start == 4.25)
        #expect(segment.end == 5.75)
    }

    @Test func completedTranscriptFallsBackToSentAudioWindowWhenNoTurnExists() throws {
        var reducer = OpenAIRealtimeEventReducer(source: .system)
        var pendingTurns: [(start: TimeInterval, end: TimeInterval)] = []

        let completed = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "item-3",
                "transcript": "Fallback timing",
            ]),
            baseSeconds: 8,
            sentSeconds: 5,
            pendingTurns: &pendingTurns
        )

        let segment = try expectFinal(completed, source: .system)
        #expect(segment.start == 11)
        #expect(segment.end == 13)
    }

    @Test func transcriptionFailedEventIsNonfatalButAuthOrModelErrorsAreFatal() throws {
        var reducer = OpenAIRealtimeEventReducer(source: .system)
        var pendingTurns: [(start: TimeInterval, end: TimeInterval)] = []

        let failed = reducer.handle(
            try eventJSON([
                "type": "conversation.item.input_audio_transcription.failed",
                "item_id": "item-4",
                "error": [
                    "type": "transcription_error",
                    "code": "audio_unintelligible",
                    "message": "The audio could not be transcribed.",
                ],
            ]),
            baseSeconds: 0,
            sentSeconds: 0,
            pendingTurns: &pendingTurns
        )
        expectNonfatal(failed, message: "The audio could not be transcribed.")

        let fatal = reducer.handle(
            try eventJSON([
                "type": "error",
                "error": [
                    "message": "Model not found for this session.",
                ],
            ]),
            baseSeconds: 0,
            sentSeconds: 0,
            pendingTurns: &pendingTurns
        )
        expectFatal(fatal, message: "Model not found for this session.")
    }

    @Test func transportReceiveFailuresFinishEventStreamAfterReconnectLimit() async throws {
        let factory = FakeRealtimeTransportFactory {
            FakeRealtimeTransport(receiveResults: [.failure(FakeRealtimeError.receiveFailed)])
        }
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: EngineEvent.self)
        let session = RealtimeSession(
            apiKey: "test-key",
            model: OpenAIRealtimeEngine.defaultTranscriptionModel,
            source: .system,
            events: eventContinuation,
            reconnectDelay: 0,
            transportFactory: factory.makeTransport
        )

        let runTask = Task { await session.run(audio: audio) }

        let error = await collectStreamError(events)

        let transcriptionError = try #require(error as? TranscriptionError)
        #expect(transcriptionError.localizedDescription.contains("Lost connection to OpenAI"))
        #expect(factory.transportCount() == 4)
        #expect(await factory.sentTextCount(containing: "\"type\":\"session.update\"") == 4)

        audioContinuation.finish()
        await session.shutdown()
        await runTask.value
    }

    @Test func reconnectFailureWhileSendingSessionUpdateAlsoFinishesEventStream() async throws {
        let factory = FakeRealtimeTransportFactory {
            FakeRealtimeTransport(
                sendResults: [.success(()), .failure(FakeRealtimeError.sendFailed)],
                receiveResults: [.failure(FakeRealtimeError.receiveFailed)]
            )
        }
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: EngineEvent.self)
        let session = RealtimeSession(
            apiKey: "test-key",
            model: OpenAIRealtimeEngine.defaultTranscriptionModel,
            source: .system,
            events: eventContinuation,
            reconnectDelay: 0,
            transportFactory: factory.makeTransport
        )

        let runTask = Task { await session.run(audio: audio) }

        let error = await collectStreamError(events)

        let transcriptionError = try #require(error as? TranscriptionError)
        #expect(transcriptionError.localizedDescription.contains("Lost connection to OpenAI"))
        #expect(factory.transportCount() == 4)

        audioContinuation.finish()
        await session.shutdown()
        await runTask.value
    }

    @Test func transientReceiveFailureReconnectsAndPreservesCommittedAudioWindow() async throws {
        let receiveScripts = LockedReceiveScripts([
            [.failure(FakeRealtimeError.receiveFailed)],
            [.success(try eventJSON([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "item-after-reconnect",
                "transcript": "Recovered after reconnect",
            ]))],
        ])
        let factory = FakeRealtimeTransportFactory {
            FakeRealtimeTransport(
                receiveResults: receiveScripts.next(),
                receiveDelay: .milliseconds(250)
            )
        }
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: EngineEvent.self)
        let session = RealtimeSession(
            apiKey: "test-key",
            model: OpenAIRealtimeEngine.defaultTranscriptionModel,
            source: .system,
            events: eventContinuation,
            reconnectDelay: 0,
            transportFactory: factory.makeTransport
        )

        let runTask = Task { await session.run(audio: audio) }

        audioContinuation.yield(try audioChunk(seconds: 2.2))
        let segment = try await firstFinalSegment(from: events)

        #expect(segment.text == "Recovered after reconnect")
        #expect(segment.speaker == .unattributed)
        #expect(abs(segment.start - 0) < 0.05)
        #expect(abs(segment.end - 2.2) < 0.05)
        #expect(factory.transportCount() >= 2)
        #expect(await factory.sentTextCount(containing: "\"type\":\"session.update\"") >= 2)
        #expect(await factory.sentTextCount(containing: "input_audio_buffer.commit") >= 1)

        audioContinuation.finish()
        await session.shutdown()
        await runTask.value
    }

    @Test func appendFailureDoesNotAdvanceCommittedAudioWindowAfterReconnect() async throws {
        let completion = try eventJSON([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item-after-append-failure",
            "transcript": "Only successful audio counts",
        ])
        let transportIndex = OSAllocatedUnfairLock(initialState: 0)
        let factory = FakeRealtimeTransportFactory {
            let index = transportIndex.withLock {
                let current = $0
                $0 += 1
                return current
            }
            if index == 0 {
                return FakeRealtimeTransport(
                    sendResults: [.success(()), .failure(FakeRealtimeError.sendFailed)]
                )
            }
            return FakeRealtimeTransport(
                receiveResults: [.success(completion)],
                receiveDelay: .milliseconds(250)
            )
        }
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: EngineEvent.self)
        let session = RealtimeSession(
            apiKey: "test-key",
            model: OpenAIRealtimeEngine.defaultTranscriptionModel,
            source: .system,
            events: eventContinuation,
            reconnectDelay: 0,
            transportFactory: factory.makeTransport
        )

        let runTask = Task { await session.run(audio: audio) }

        audioContinuation.yield(try audioChunk(seconds: 2.2))
        audioContinuation.yield(try audioChunk(seconds: 2.2))
        let segment = try await firstFinalSegment(from: events)

        #expect(segment.text == "Only successful audio counts")
        #expect(abs(segment.start - 0) < 0.05)
        #expect(abs(segment.end - 2.2) < 0.05)
        #expect(factory.transportCount() >= 2)
        #expect(await factory.sentTextCount(containing: "input_audio_buffer.append") >= 2)
        #expect(await factory.sentTextCount(containing: "input_audio_buffer.commit") == 1)

        audioContinuation.finish()
        await session.shutdown()
        await runTask.value
    }

    private func eventJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func collectStreamError(
        _ events: AsyncThrowingStream<EngineEvent, Error>
    ) async -> Error? {
        do {
            for try await _ in events {}
            return nil
        } catch {
            return error
        }
    }

    private func firstFinalSegment(
        from events: AsyncThrowingStream<EngineEvent, Error>
    ) async throws -> TranscriptSegment {
        try await withThrowingTaskGroup(of: TranscriptSegment.self) { group in
            group.addTask {
                for try await event in events {
                    if case .final(let segment) = event {
                        return segment
                    }
                }
                throw FakeRealtimeError.noFinalSegment
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw FakeRealtimeError.timeout
            }

            let segment = try await group.next()!
            group.cancelAll()
            return segment
        }
    }

    private func audioChunk(seconds: Double) throws -> AudioChunk {
        let sampleRate = 24_000.0
        let frameCount = AVAudioFrameCount((seconds * sampleRate).rounded())
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                data[0][i] = 0.1
            }
        }
        return AudioChunk(buffer: buffer, hostTime: nil)
    }

    private func expectVolatile(
        _ actions: [OpenAIRealtimeEventReducer.Action],
        source: AudioSource,
        text: String
    ) {
        guard case .event(.volatile(let actualSource, let actualText)) = actions.first else {
            Issue.record("Expected volatile event.")
            return
        }
        #expect(actions.count == 1)
        #expect(actualSource == source)
        #expect(actualText == text)
    }

    private func expectVolatileClear(
        _ actions: [OpenAIRealtimeEventReducer.Action],
        source: AudioSource
    ) {
        guard case .event(.volatile(let actualSource, let actualText)) = actions.first else {
            Issue.record("Expected volatile clear event.")
            return
        }
        #expect(actualSource == source)
        #expect(actualText.isEmpty)
    }

    private func expectFinal(
        _ actions: [OpenAIRealtimeEventReducer.Action],
        source: AudioSource
    ) throws -> TranscriptSegment {
        let final = actions.compactMap { action -> TranscriptSegment? in
            if case .event(.final(let segment)) = action {
                return segment
            }
            return nil
        }.first
        let segment = try #require(final)
        #expect(segment.source == source)
        #expect(segment.isFinal)
        return segment
    }

    private func expectNonfatal(
        _ actions: [OpenAIRealtimeEventReducer.Action],
        message: String
    ) {
        guard case .nonfatalError(let actualMessage) = actions.first else {
            Issue.record("Expected nonfatal error.")
            return
        }
        #expect(actions.count == 1)
        #expect(actualMessage == message)
    }

    private func expectFatal(
        _ actions: [OpenAIRealtimeEventReducer.Action],
        message: String
    ) {
        guard case .fatalError(let actualMessage) = actions.first else {
            Issue.record("Expected fatal error.")
            return
        }
        #expect(actions.count == 1)
        #expect(actualMessage == message)
    }
}

private enum FakeRealtimeError: Error {
    case receiveFailed
    case sendFailed
    case noFinalSegment
    case timeout
}

private final class LockedReceiveScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[Result<String?, Error>]]

    init(_ scripts: [[Result<String?, Error>]]) {
        self.scripts = scripts
    }

    func next() -> [Result<String?, Error>] {
        lock.lock()
        defer { lock.unlock() }
        guard !scripts.isEmpty else { return [] }
        return scripts.removeFirst()
    }
}

private final class FakeRealtimeTransportFactory: @unchecked Sendable {
    private let builder: @Sendable () -> FakeRealtimeTransport
    private let transports = OSAllocatedUnfairLock(initialState: [FakeRealtimeTransport]())

    init(builder: @escaping @Sendable () -> FakeRealtimeTransport) {
        self.builder = builder
    }

    func makeTransport(request: URLRequest) -> any OpenAIRealtimeTransport {
        let transport = builder()
        transports.withLock { $0.append(transport) }
        return transport
    }

    func transportCount() -> Int {
        transports.withLock { $0.count }
    }

    func sentTextCount(containing needle: String) async -> Int {
        let snapshot = transports.withLock { $0 }
        var count = 0
        for transport in snapshot {
            count += await transport.sentTextCount(containing: needle)
        }
        return count
    }
}

private actor FakeRealtimeTransport: OpenAIRealtimeTransport {
    private var sendResults: [Result<Void, Error>]
    private var receiveResults: [Result<String?, Error>]
    private let receiveDelay: Duration?
    private var sentTexts: [String] = []

    init(
        sendResults: [Result<Void, Error>] = [],
        receiveResults: [Result<String?, Error>] = [],
        receiveDelay: Duration? = nil
    ) {
        self.sendResults = sendResults
        self.receiveResults = receiveResults
        self.receiveDelay = receiveDelay
    }

    func resume() {}

    func send(text: String) async throws {
        sentTexts.append(text)
        if !sendResults.isEmpty {
            try sendResults.removeFirst().get()
        }
    }

    func receiveText() async throws -> String? {
        if let receiveDelay {
            try await Task.sleep(for: receiveDelay)
        }
        if !receiveResults.isEmpty {
            return try receiveResults.removeFirst().get()
        }
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        throw CancellationError()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode) {}

    func sentTextCount(containing needle: String) -> Int {
        sentTexts.count { $0.contains(needle) }
    }
}
