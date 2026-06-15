import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

/// On-device ASR using Apple's SpeechAnalyzer + SpeechTranscriber (macOS 26+).
/// Two analyzer pipelines run concurrently — one per capture stream — so the
/// mic ("You") and system audio (remote participants) are transcribed
/// independently on the same session timeline.
@MainActor
final class LocalSpeechEngine: TranscriptionEngine {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "LocalASR")

    let kind: ASREngineChoice = .local
    private var locale: Locale = .current
    private var pipelines: [StreamPipeline] = []
    private var eventsContinuation: AsyncThrowingStream<EngineEvent, Error>.Continuation?
    private var runTask: Task<Void, Never>?

    func prepare(locale: Locale, progress: @MainActor @escaping (Double) -> Void) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = Self.resolveSupportedLocale(from: locale, supported: supported) else {
            throw TranscriptionError.localeNotSupported(locale.identifier)
        }
        self.locale = resolved

        let probe = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            let downloadProgress = request.progress
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress(downloadProgress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { poll.cancel() }
            do {
                try await request.downloadAndInstall()
            } catch {
                throw TranscriptionError.modelDownloadFailed(error.localizedDescription)
            }
        }
        progress(1.0)
    }

    /// Match a user/system locale (which may carry extensions like
    /// `en_US@rg=auzzzz`) against the model's supported locale list.
    nonisolated static func resolveSupportedLocale(
        from requested: Locale,
        supported: [Locale]
    ) -> Locale? {
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == requested.identifier(.bcp47)
        }) {
            return exact
        }
        let language = requested.language.languageCode?.identifier
        guard language != nil else { return nil }

        let overrideRegion = requested.region?.identifier
        let baseRegion = Locale.Components(identifier: requested.identifier).region?.identifier
        for region in [overrideRegion, baseRegion].compactMap({ $0 }) {
            if let match = supported.first(where: {
                $0.language.languageCode?.identifier == language
                    && $0.region?.identifier == region
            }) {
                return match
            }
        }
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    func start(
        micStream: AsyncStream<AudioChunk>,
        systemStream: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<EngineEvent, Error> {
        let (events, eventsCont) = AsyncThrowingStream.makeStream(of: EngineEvent.self)

        let mic = try await StreamPipeline(
            source: .microphone, locale: locale, audio: micStream, events: eventsCont)
        let system = try await StreamPipeline(
            source: .system, locale: locale, audio: systemStream, events: eventsCont)
        pipelines = [mic, system]
        eventsContinuation = eventsCont

        let activePipelines = pipelines
        runTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for pipeline in activePipelines {
                    group.addTask { await pipeline.run() }
                }
            }
            eventsCont.finish()
        }
        return events
    }

    func stop() async {
        for pipeline in pipelines {
            await pipeline.shutdown()
        }
        eventsContinuation?.finish()
        runTask?.cancel()
        pipelines = []
        eventsContinuation = nil
        runTask = nil
    }
}

enum LocalASRFinalizationOutcome: Equatable, Sendable {
    case completed
    case timedOut
}

enum LocalASRFinalization {
    static func run(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> LocalASRFinalizationOutcome {
        let gate = LocalASRFinalizationGate()
        let operationTask = Task {
            await operation()
            await gate.resume(.completed)
        }

        return await withCheckedContinuation { continuation in
            Task {
                await gate.install(continuation)
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.resume(.timedOut) {
                    operationTask.cancel()
                }
            }
        }
    }
}

private actor LocalASRFinalizationGate {
    private var outcome: LocalASRFinalizationOutcome?
    private var continuation: CheckedContinuation<LocalASRFinalizationOutcome, Never>?

    func install(_ continuation: CheckedContinuation<LocalASRFinalizationOutcome, Never>) {
        if let outcome {
            continuation.resume(returning: outcome)
        } else {
            self.continuation = continuation
        }
    }

    @discardableResult
    func resume(_ outcome: LocalASRFinalizationOutcome) -> Bool {
        guard self.outcome == nil else { return false }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
        return true
    }
}

/// One SpeechAnalyzer pipeline bound to a single audio source.
private actor StreamPipeline {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "ASRPipeline")
    private static let finalizationTimeout: Duration = .seconds(5)

    private let source: AudioSource
    private let audio: AsyncStream<AudioChunk>
    private let events: AsyncThrowingStream<EngineEvent, Error>.Continuation
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat?
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var feedTask: Task<Void, Never>?
    private var stopped = false
    private var fedFrames: AVAudioFramePosition = 0
    private var analyzerTimeScale: CMTimeScale = 600

    init(
        source: AudioSource,
        locale: Locale,
        audio: AsyncStream<AudioChunk>,
        events: AsyncThrowingStream<EngineEvent, Error>.Continuation
    ) async throws {
        self.source = source
        self.audio = audio
        self.events = events

        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputSequence, builder) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(AudioStreamBuffer.chunkLimit)
        )
        inputBuilder = builder
        try await analyzer.start(inputSequence: inputSequence)
    }

    /// Consumes audio + results until the audio stream ends; returns when the
    /// result stream is fully drained.
    func run() async {
        feedTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.audio {
                await self.feed(chunk)
            }
            await self.finishInput()
        }

        do {
            for try await result in transcriber.results {
                handle(result)
            }
        } catch {
            Self.log.error("[\(self.source.rawValue)] results failed: \(error.localizedDescription)")
            events.yield(.volatile(source: source, text: ""))
        }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        feedTask?.cancel()
        inputBuilder.finish()
        await finishAnalyzer()
    }

    private func finishInput() async {
        guard !stopped else { return }
        stopped = true
        inputBuilder.finish()
        await finishAnalyzer()
    }

    private func feed(_ chunk: AudioChunk) {
        guard let analyzerFormat else { return }
        let buffer: AVAudioPCMBuffer
        if chunk.format == analyzerFormat {
            buffer = chunk.buffer
        } else {
            if converter == nil || converter?.inputFormat != chunk.format {
                converter = AVAudioConverter(from: chunk.format, to: analyzerFormat)
                converter?.primeMethod = .none
            }
            guard let converter else { return }
            let ratio = analyzerFormat.sampleRate / chunk.format.sampleRate
            let capacity = AVAudioFrameCount((Double(chunk.frameCount) * ratio).rounded(.up) + 64)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var consumed = false
            nonisolated(unsafe) let input = chunk.buffer
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            guard status != .error, converted.frameLength > 0 else { return }
            buffer = converted
        }
        analyzerTimeScale = CMTimeScale(max(1, Int(buffer.format.sampleRate.rounded())))
        let startFrame = fedFrames
        fedFrames += AVAudioFramePosition(buffer.frameLength)
        let startTime = CMTime(value: CMTimeValue(startFrame), timescale: analyzerTimeScale)
        let result = inputBuilder.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
        AudioStreamBuffer.recordYield(result, label: "\(source.rawValue) analyzer input")
    }

    private func finishAnalyzer() async {
        if fedFrames > 0 {
            let endTime = CMTime(value: CMTimeValue(fedFrames), timescale: analyzerTimeScale)
            let outcome = await LocalASRFinalization.run(
                timeout: Self.finalizationTimeout
            ) { [analyzer] in
                try? await analyzer.finalizeAndFinish(through: endTime)
            }
            if outcome == .timedOut {
                Self.log.error("[\(self.source.rawValue)] analyzer finalization timed out")
                await analyzer.cancelAndFinishNow()
            }
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            events.yield(.volatile(source: source, text: ""))
            guard !text.isEmpty else { return }
            let (start, end) = Self.timeRange(of: result.text, fallback: result.range)
            let segment = TranscriptSegment(
                source: source,
                speaker: source == .microphone ? .you : .unattributed,
                text: text,
                start: start,
                end: end,
                isFinal: true
            )
            events.yield(.final(segment))
        } else {
            events.yield(.volatile(source: source, text: text))
        }
    }

    /// Extract covered audio time from per-run attributes, falling back to the
    /// result's overall range.
    private static func timeRange(
        of text: AttributedString,
        fallback: CMTimeRange
    ) -> (TimeInterval, TimeInterval) {
        var start = TimeInterval.greatestFiniteMagnitude
        var end: TimeInterval = 0
        for run in text.runs {
            if let range = run.audioTimeRange {
                start = min(start, range.start.seconds)
                end = max(end, range.end.seconds)
            }
        }
        if start > end {
            return (max(0, fallback.start.seconds), max(0, fallback.end.seconds))
        }
        return (start, end)
    }
}
