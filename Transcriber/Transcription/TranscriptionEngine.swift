import Foundation

/// Events emitted by a transcription engine during a session.
enum EngineEvent: Sendable {
    /// Live in-progress hypothesis for a source; replaces the previous volatile text.
    case volatile(source: AudioSource, text: String)
    /// A finalized segment. System-source segments arrive with `.unattributed`
    /// speaker and are assigned by the diarization attributor downstream.
    case final(TranscriptSegment)
}

/// A speech-to-text engine consuming both capture streams and emitting
/// speaker-agnostic transcript events. Implementations: `LocalSpeechEngine`
/// (Apple SpeechTranscriber) and `OpenAIRealtimeEngine`.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var kind: ASREngineChoice { get }

    /// Ensure models/connectivity are ready. May download assets; reports 0...1.
    func prepare(locale: Locale, progress: @MainActor @escaping (Double) -> Void) async throws

    /// Begin consuming the capture streams. Returns the event stream; the
    /// stream finishes after `stop()` drains any tail results.
    func start(
        micStream: AsyncStream<AudioChunk>,
        systemStream: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<EngineEvent, Error>

    /// Stop consuming audio and finalize pending results.
    func stop() async
}

enum TranscriptionError: LocalizedError {
    case localeNotSupported(String)
    case modelDownloadFailed(String)
    case engineFailed(String)
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let id):
            "The language “\(id)” isn’t supported for on-device transcription."
        case .modelDownloadFailed(let reason):
            "The speech model couldn’t be downloaded: \(reason)"
        case .engineFailed(let reason):
            "Transcription failed: \(reason)"
        case .notConfigured(let reason):
            reason
        }
    }
}
