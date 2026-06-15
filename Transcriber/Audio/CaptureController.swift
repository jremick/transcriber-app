import AVFoundation
import Foundation
import os

/// Owns both capture services for a session, fans audio out to consumers,
/// computes UI level meters, and optionally writes debug WAV dumps
/// (`defaults write dev.local.transcriber debugAudioDump -bool YES`).
@MainActor
@Observable
final class CaptureController {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "Capture")

    struct Streams {
        let mic: AsyncStream<AudioChunk>
        let system: AsyncStream<AudioChunk>
        /// Duplicate of the system stream for the diarizer, so ASR and
        /// diarization each get full-rate audio on identical timelines.
        let systemDiarization: AsyncStream<AudioChunk>
    }

    private struct AudioSink: Sendable {
        let label: String
        let continuation: AsyncStream<AudioChunk>.Continuation
    }

    private let mic = MicCaptureService()
    private let systemTap = SystemAudioTapService()
    private var pumpTasks: [Task<Void, Never>] = []
    private var debugFiles: [AudioDebugFile] = []
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private var clock: SessionClock?
    private var mappers: [AudioSource: TimelineMapper] = [:]

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var isRunning = false
    /// Non-fatal: the mic couldn't start (e.g. exclusive use by another app);
    /// the session continues with system audio only.
    private(set) var micUnavailable = false

    var isPaused: Bool {
        get { paused.withLock { $0 } }
        set { paused.withLock { $0 = newValue } }
    }

    /// Convert a stream's fed-audio timestamp to session time.
    func sessionTime(for source: AudioSource, audioTime: TimeInterval) -> TimeInterval {
        mappers[source]?.sessionTime(forAudioTime: audioTime) ?? audioTime
    }

    func start(clock: SessionClock) async throws -> Streams {
        self.clock = clock
        precondition(!isRunning)
        micUnavailable = false
        guard await MicCaptureService.requestPermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // System audio first — it's the heart of meeting capture. A failed mic
        // degrades the session (no "You" channel) instead of killing it.
        let systemRaw = try systemTap.start()
        var micRaw: AsyncStream<AudioChunk>
        do {
            micRaw = try await mic.start()
            micUnavailable = false
        } catch {
            DebugDiag.log("mic unavailable; continuing system-only: \(error)")
            Self.log.warning("Microphone unavailable; continuing system-only: \(error.localizedDescription, privacy: .public)")
            micUnavailable = true
            let (empty, emptyCont) = AsyncStream.makeStream(of: AudioChunk.self)
            emptyCont.finish()
            micRaw = empty
        }

        let dumpEnabled = UserDefaults.standard.bool(forKey: "debugAudioDump")
        let micDump = dumpEnabled ? AudioDebugFile(label: "mic") : nil
        let systemDump = dumpEnabled ? AudioDebugFile(label: "system") : nil
        debugFiles = [micDump, systemDump].compactMap { $0 }

        let micMapper = TimelineMapper()
        let systemMapper = TimelineMapper()
        mappers = [.microphone: micMapper, .system: systemMapper]

        let (micOut, micCont) = AudioStreamBuffer.makeStream()
        let (sysOut, sysCont) = AudioStreamBuffer.makeStream()
        let (diarOut, diarCont) = AudioStreamBuffer.makeStream()
        pumpTasks = [
            pump(
                micRaw,
                source: .microphone,
                into: [AudioSink(label: "mic asr", continuation: micCont)],
                dump: micDump,
                mapper: micMapper,
                clock: clock
            ),
            pump(
                systemRaw,
                source: .system,
                into: [
                    AudioSink(label: "system asr", continuation: sysCont),
                    AudioSink(label: "system diarization", continuation: diarCont),
                ],
                dump: systemDump,
                mapper: systemMapper,
                clock: clock
            ),
        ]

        isPaused = false
        isRunning = true
        return Streams(mic: micOut, system: sysOut, systemDiarization: diarOut)
    }

    func stop() {
        guard isRunning else { return }
        mic.stop()
        systemTap.stop()
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        for file in debugFiles { file.close() }
        debugFiles = []
        micLevel = 0
        systemLevel = 0
        micUnavailable = false
        isRunning = false
    }

    private func pump(
        _ input: AsyncStream<AudioChunk>,
        source: AudioSource,
        into outs: [AudioSink],
        dump: AudioDebugFile?,
        mapper: TimelineMapper,
        clock: SessionClock
    ) -> Task<Void, Never> {
        let pausedFlag = paused
        return Task.detached(priority: .userInitiated) { [weak self] in
            var lastLevelAt = ContinuousClock.now
            for await chunk in input {
                if Task.isCancelled { break }
                let isPaused = pausedFlag.withLock { $0 }
                if !isPaused {
                    mapper.record(duration: chunk.duration, at: clock.now())
                    for out in outs {
                        let result = out.continuation.yield(chunk)
                        AudioStreamBuffer.recordYield(result, label: out.label)
                    }
                    dump?.write(chunk)
                }
                let now = ContinuousClock.now
                if now - lastLevelAt > .milliseconds(80) {
                    lastLevelAt = now
                    let level = isPaused ? 0 : chunk.rmsLevel
                    Task { @MainActor [weak self] in
                        self?.setLevel(level, for: source)
                    }
                }
            }
            for out in outs { out.continuation.finish() }
        }
    }

    private func setLevel(_ level: Float, for source: AudioSource) {
        switch source {
        case .microphone: micLevel = level
        case .system: systemLevel = level
        }
    }
}

/// Debug-only WAV writer; file format is fixed from the first chunk.
final class AudioDebugFile: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let url: URL

    init?(label: String) {
        let dir = DebugArtifacts.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        url = dir.appending(path: "\(label)-\(stamp).wav")
    }

    func write(_ chunk: AudioChunk) {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            file = try? AVAudioFile(
                forWriting: url,
                settings: chunk.format.settings,
                commonFormat: chunk.format.commonFormat,
                interleaved: chunk.format.isInterleaved
            )
        }
        try? file?.write(from: chunk.buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}
