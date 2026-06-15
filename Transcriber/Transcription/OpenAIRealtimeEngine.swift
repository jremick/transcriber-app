import AVFoundation
import Foundation
import OSLog

/// Cloud ASR via OpenAI's Realtime transcription WebSocket. One connection per
/// capture stream. Text only — speaker attribution remains local (FluidAudio),
/// so this engine reports segments with time ranges derived from manual audio
/// commit windows mapped onto the audio we actually sent. VAD events are still
/// handled for compatibility with models that emit them.
@MainActor
final class OpenAIRealtimeEngine: TranscriptionEngine {
    static let defaultTranscriptionModel = "gpt-realtime-whisper"

    let kind: ASREngineChoice = .openAI

    private let apiKey: String
    private let model: String
    private let transportFactory: OpenAIRealtimeTransportFactory
    private var sessions: [RealtimeSession] = []

    init(
        apiKey: String,
        model: String,
        transportFactory: @escaping OpenAIRealtimeTransportFactory = URLSessionOpenAIRealtimeTransport.init
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transportFactory = transportFactory
    }

    func prepare(locale: Locale, progress: @MainActor @escaping (Double) -> Void) async throws {
        // Cheap connectivity/key sanity check before the meeting starts.
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/\(model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw TranscriptionError.notConfigured(
                    "OpenAI rejected the API key. Check Settings → Account.")
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                throw TranscriptionError.notConfigured(
                    "Model “\(model)” not found. Check Settings → Transcription.")
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engineFailed(
                "Can't reach OpenAI: \(error.localizedDescription)")
        }
        progress(1.0)
    }

    func start(
        micStream: AsyncStream<AudioChunk>,
        systemStream: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<EngineEvent, Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: EngineEvent.self)
        let mic = RealtimeSession(
            apiKey: apiKey,
            model: model,
            source: .microphone,
            events: continuation,
            transportFactory: transportFactory
        )
        let system = RealtimeSession(
            apiKey: apiKey,
            model: model,
            source: .system,
            events: continuation,
            transportFactory: transportFactory
        )
        sessions = [mic, system]

        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await mic.run(audio: micStream) }
                group.addTask { await system.run(audio: systemStream) }
            }
            continuation.finish()
        }
        return events
    }

    func stop() async {
        for session in sessions {
            await session.shutdown()
        }
        sessions = []
    }

    nonisolated static func sessionUpdateJSON(model: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: sessionUpdatePayload(model: model))
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func sessionUpdatePayload(model: String) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": ["model": model],
                    ]
                ],
            ],
        ]
    }
}

typealias OpenAIRealtimeTransportFactory = @Sendable (URLRequest) -> any OpenAIRealtimeTransport

protocol OpenAIRealtimeTransport: Sendable {
    func resume() async
    func send(text: String) async throws
    func receiveText() async throws -> String?
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode) async
}

private actor URLSessionOpenAIRealtimeTransport: OpenAIRealtimeTransport {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        self.task = URLSession.shared.webSocketTask(with: request)
    }

    func resume() {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String? {
        switch try await task.receive() {
        case .string(let text):
            text
        case .data:
            nil
        @unknown default:
            nil
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode) {
        task.cancel(with: closeCode, reason: nil)
    }
}

struct OpenAIRealtimeEventReducer {
    enum Action {
        case event(EngineEvent)
        case nonfatalError(String)
        case fatalError(String)
    }

    private let source: AudioSource
    private var openTurnStart: TimeInterval?
    private var itemText: [String: String] = [:]

    init(source: AudioSource) {
        self.source = source
    }

    mutating func handle(
        _ text: String,
        baseSeconds: TimeInterval,
        sentSeconds: TimeInterval,
        pendingTurns: inout [(start: TimeInterval, end: TimeInterval)]
    ) -> [Action] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return [] }

        switch type {
        case "input_audio_buffer.speech_started":
            let ms = (json["audio_start_ms"] as? Double) ?? (sentSeconds * 1000)
            openTurnStart = baseSeconds + ms / 1000
            return []

        case "input_audio_buffer.speech_stopped":
            let ms = (json["audio_end_ms"] as? Double) ?? (sentSeconds * 1000)
            let end = baseSeconds + ms / 1000
            let start = openTurnStart ?? max(0, end - 1)
            openTurnStart = nil
            pendingTurns.append((start, end))
            return []

        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = json["item_id"] as? String,
                  let delta = json["delta"] as? String else { return [] }
            itemText[itemID, default: ""] += delta
            return [.event(.volatile(source: source, text: itemText[itemID] ?? ""))]

        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = (json["transcript"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return [] }
            if let itemID = json["item_id"] as? String {
                itemText[itemID] = nil
            }
            var actions: [Action] = [.event(.volatile(source: source, text: ""))]
            guard !transcript.isEmpty else { return actions }
            let turn = pendingTurns.isEmpty ? nil : pendingTurns.removeFirst()
            let end = turn?.end ?? (baseSeconds + sentSeconds)
            let start = turn?.start ?? max(0, end - 2)
            actions.append(.event(.final(TranscriptSegment(
                source: source,
                speaker: source == .microphone ? .you : .unattributed,
                text: transcript,
                start: start,
                end: end,
                isFinal: true
            ))))
            return actions

        case "conversation.item.input_audio_transcription.failed":
            return [.nonfatalError(Self.errorMessage(from: json))]

        case "error":
            let message = Self.errorMessage(from: json)
            return Self.isFatalError(message)
                ? [.fatalError(message)]
                : [.nonfatalError(message)]

        default:
            return []
        }
    }

    private static func errorMessage(from json: [String: Any]) -> String {
        ((json["error"] as? [String: Any])?["message"] as? String)
            ?? "Unknown realtime API error"
    }

    private static func isFatalError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("model")
            || message.localizedCaseInsensitiveContains("auth")
    }
}

/// One WebSocket transcription session bound to a single audio source.
actor RealtimeSession {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "OpenAIRealtime")

    private let apiKey: String
    private let model: String
    private let source: AudioSource
    private let events: AsyncThrowingStream<EngineEvent, Error>.Continuation
    private let transportFactory: OpenAIRealtimeTransportFactory
    private let reconnectDelay: TimeInterval

    private var transport: (any OpenAIRealtimeTransport)?
    private var receiveTask: Task<Void, Never>?
    private var resampler: AudioResampler?
    private var stopped = false

    /// Seconds of audio sent on the *current* connection.
    private var sentSeconds: TimeInterval = 0
    /// Audio sent on previous (dropped) connections; keeps the timeline whole.
    private var baseSeconds: TimeInterval = 0
    /// FIFO of VAD turn boundaries (audio time) awaiting completed transcripts.
    private var pendingTurns: [(start: TimeInterval, end: TimeInterval)] = []
    private var pendingCommitStart: TimeInterval?
    private var pendingCommitEnd: TimeInterval?
    private var reducer: OpenAIRealtimeEventReducer
    private var consecutiveFailures = 0
    private let manualCommitSeconds: TimeInterval = 2

    init(
        apiKey: String, model: String, source: AudioSource,
        events: AsyncThrowingStream<EngineEvent, Error>.Continuation,
        reconnectDelay: TimeInterval = 1,
        transportFactory: @escaping OpenAIRealtimeTransportFactory = URLSessionOpenAIRealtimeTransport.init
    ) {
        self.apiKey = apiKey
        self.model = model
        self.source = source
        self.events = events
        self.transportFactory = transportFactory
        self.reconnectDelay = reconnectDelay
        self.reducer = OpenAIRealtimeEventReducer(source: source)
    }

    func run(audio: AsyncStream<AudioChunk>) async {
        do {
            try await connect()
        } catch {
            events.finish(throwing: error)
            return
        }

        for await chunk in audio {
            if stopped { break }
            await send(chunk: chunk)
        }
        await flushPendingCommit()
        guard !stopped else { return }
        // End of audio: give the server a moment to flush, then close.
        try? await Task.sleep(for: .seconds(2))
        guard !stopped else { return }
        await shutdown()
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        receiveTask?.cancel()
        await transport?.cancel(with: .normalClosure)
        transport = nil
    }

    // MARK: - Connection

    private func connect() async throws {
        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let transport = transportFactory(request)
        self.transport = transport
        await transport.resume()

        try await sendJSONString(OpenAIRealtimeEngine.sessionUpdateJSON(model: model))

        baseSeconds += sentSeconds
        sentSeconds = 0
        receiveTask = Task { await receiveLoop() }
    }

    private func reconnect() async {
        guard !stopped else { return }
        while !stopped {
            consecutiveFailures += 1
            guard consecutiveFailures <= 3 else {
                events.finish(throwing: TranscriptionError.engineFailed(
                    "Lost connection to OpenAI after several retries."))
                stopped = true
                return
            }
            Self.log.warning("[\(self.source.rawValue)] reconnecting (attempt \(self.consecutiveFailures))")
            receiveTask?.cancel()
            await transport?.cancel(with: .abnormalClosure)
            transport = nil
            if reconnectDelay > 0 {
                try? await Task.sleep(for: .seconds(reconnectDelay))
            }
            do {
                try await connect()
                return
            } catch {
                Self.log.error("[\(self.source.rawValue)] reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Sending

    private func send(chunk: AudioChunk) async {
        guard transport != nil else { return }
        if resampler == nil {
            resampler = AudioResampler(from: chunk.format, toSampleRate: 24000)
        }
        guard let resampler else { return }
        let floats = resampler.convertToFloats(chunk.buffer)
        guard !floats.isEmpty else { return }

        var pcm16 = [Int16](repeating: 0, count: floats.count)
        for i in 0..<floats.count {
            pcm16[i] = Int16(max(-1, min(1, floats[i])) * 32767)
        }
        let data = pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
        let chunkStart = baseSeconds + sentSeconds
        let duration = Double(floats.count) / 24000.0
        let chunkEnd = chunkStart + duration

        do {
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ])
            sentSeconds += duration
            notePendingCommit(start: chunkStart, end: chunkEnd)
            if let start = pendingCommitStart, chunkEnd - start >= manualCommitSeconds {
                try await commitPendingAudio()
            }
        } catch {
            await reconnect()
        }
    }

    private func notePendingCommit(start: TimeInterval, end: TimeInterval) {
        if pendingCommitStart == nil {
            pendingCommitStart = start
        }
        pendingCommitEnd = end
    }

    private func flushPendingCommit() async {
        do {
            try await commitPendingAudio()
        } catch {
            await reconnect()
        }
    }

    private func commitPendingAudio() async throws {
        guard let start = pendingCommitStart,
              let end = pendingCommitEnd,
              end > start
        else { return }
        try await sendJSON(["type": "input_audio_buffer.commit"])
        pendingTurns.append((start, end))
        pendingCommitStart = nil
        pendingCommitEnd = nil
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await sendJSONString(String(decoding: data, as: UTF8.self))
    }

    private func sendJSONString(_ text: String) async throws {
        guard let transport else { return }
        try await transport.send(text: text)
    }

    // MARK: - Receiving

    private func receiveLoop() async {
        while !Task.isCancelled, let transport {
            do {
                let text = try await transport.receiveText()
                consecutiveFailures = 0
                if let text {
                    handle(text)
                }
            } catch {
                if !stopped {
                    await reconnect()
                }
                return
            }
        }
    }

    private func handle(_ text: String) {
        let actions = reducer.handle(
            text,
            baseSeconds: baseSeconds,
            sentSeconds: sentSeconds,
            pendingTurns: &pendingTurns
        )
        for action in actions {
            switch action {
            case .event(let event):
                events.yield(event)
            case .nonfatalError(let message):
                Self.log.error("[\(self.source.rawValue)] API error: \(message, privacy: .public)")
                DebugDiag.log("openai realtime error (\(source.rawValue)): \(message)")
            case .fatalError(let message):
                Self.log.error("[\(self.source.rawValue)] fatal API error: \(message, privacy: .public)")
                DebugDiag.log("openai realtime fatal error (\(source.rawValue)): \(message)")
                events.finish(throwing: TranscriptionError.engineFailed(message))
                stopped = true
            }
        }
    }
}
