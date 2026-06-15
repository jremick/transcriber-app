import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// A finalized "speaker X was talking from A to B" interval, in the system
/// stream's fed-audio time (same timeline the ASR timestamps use).
struct SpeakerInterval: Sendable, Equatable {
    let clusterIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// Streaming speaker diarization of the system-audio stream using FluidAudio's
/// LS-EEND model. Runs fully on-device regardless of the ASR engine choice.
actor DiarizationService {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "Diarization")

    private var diarizer: LSEENDDiarizer?
    private var runTask: Task<Void, Never>?
    /// Total audio fed across all runs; each `run` reports 0-based times so a
    /// mid-session engine switch (new capture stream) stays consistent with
    /// the ASR's restarted timeline, while the diarizer keeps speaker state.
    private var totalFedSeconds: TimeInterval = 0
    private var processingAttemptCount = 0
    private var processingErrorCount = 0
    private var lastProcessingErrorDescription: String?

    func resetForNewSession() {
        stop()
        diarizer = nil
        totalFedSeconds = 0
        processingAttemptCount = 0
        processingErrorCount = 0
        lastProcessingErrorDescription = nil
    }

    func prepare() async throws {
        guard diarizer == nil else { return }
        do {
            diarizer = try await LSEENDDiarizer(
                variant: .dihard3,
                stepSize: .step100ms,
                timelineConfig: nil
            )
            Self.log.info("LS-EEND diarizer ready")
        } catch {
            throw TranscriptionError.modelDownloadFailed(
                "Speaker-identification model: \(error.localizedDescription)")
        }
    }

    /// Consume the diarization copy of the system stream; emit finalized
    /// speaker intervals. The returned stream finishes when the input ends.
    func run(stream: AsyncStream<AudioChunk>) -> AsyncStream<SpeakerInterval> {
        let (intervals, continuation) = AsyncStream.makeStream(of: SpeakerInterval.self)
        runTask = Task {
            await self.consume(stream: stream, continuation: continuation)
        }
        return intervals
    }

    private func consume(
        stream: AsyncStream<AudioChunk>,
        continuation: AsyncStream<SpeakerInterval>.Continuation
    ) async {
        guard let diarizer else {
            continuation.finish()
            return
        }
        let runBase = totalFedSeconds
        var resampler: AudioResampler?
        var emitted = 0
        for await chunk in stream {
            if Task.isCancelled { break }
            if resampler == nil {
                resampler = AudioResampler(from: chunk.format, toSampleRate: 16_000)
            }
            guard let resampler else { continue }
            let samples = resampler.convertToFloats(chunk.buffer)
            guard !samples.isEmpty else { continue }
            totalFedSeconds += Double(samples.count) / 16_000
            do {
                processingAttemptCount += 1
                if let update = try diarizer.process(samples: samples, sourceSampleRate: 16_000) {
                    if !update.finalizedSegments.isEmpty {
                        emitted += update.finalizedSegments.count
                        let desc = update.finalizedSegments
                            .map { "c\($0.speakerIndex) \(String(format: "%.1f-%.1f", $0.startTime, $0.endTime))" }
                            .joined(separator: ", ")
                        DebugDiag.log("diar intervals (\(emitted) total): \(desc)")
                    }
                    yieldSegments(update.finalizedSegments, base: runBase, into: continuation)
                }
            } catch {
                processingErrorCount += 1
                lastProcessingErrorDescription = error.localizedDescription
                Self.log.error("Diarizer error: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let final = try? diarizer.finalizeSession() {
            yieldSegments(final.finalizedSegments, base: runBase, into: continuation)
        }
        continuation.finish()
    }

    private func yieldSegments(
        _ segments: [DiarizerSegment],
        base: TimeInterval,
        into continuation: AsyncStream<SpeakerInterval>.Continuation
    ) {
        for segment in segments {
            continuation.yield(SpeakerInterval(
                clusterIndex: segment.speakerIndex,
                start: max(0, TimeInterval(segment.startTime) - base),
                end: max(0, TimeInterval(segment.endTime) - base)
            ))
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }
}

#if DEBUG
extension DiarizationService {
    struct DebugState: Sendable, Equatable {
        let hasDiarizer: Bool
        let totalFedSeconds: TimeInterval
        let processingAttemptCount: Int
        let processingErrorCount: Int
        let lastProcessingErrorDescription: String?
    }

    func debugAdvanceFedSecondsForTests(_ seconds: TimeInterval) {
        totalFedSeconds += seconds
    }

    func debugStateForTests() -> DebugState {
        DebugState(
            hasDiarizer: diarizer != nil,
            totalFedSeconds: totalFedSeconds,
            processingAttemptCount: processingAttemptCount,
            processingErrorCount: processingErrorCount,
            lastProcessingErrorDescription: lastProcessingErrorDescription
        )
    }
}
#endif
