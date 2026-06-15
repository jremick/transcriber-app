import Foundation

/// Lifecycle of a transcription session.
enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused

    var isActive: Bool {
        switch self {
        case .recording, .paused, .preparing: true
        case .idle: false
        }
    }
}

/// Which capture stream a piece of audio/text came from.
enum AudioSource: String, Codable, Sendable {
    /// The local user's microphone.
    case microphone
    /// System audio (remote meeting participants).
    case system
}

/// Stable per-session speaker identity.
struct SpeakerID: Hashable, Sendable, Codable {
    let key: String

    /// The local user (microphone stream).
    static let you = SpeakerID(key: "you")
    /// Remote speaker derived from diarization cluster `n`.
    static func remote(_ n: Int) -> SpeakerID { SpeakerID(key: "spk-\(n)") }
    /// Remote audio before diarization has assigned a cluster.
    static let unattributed = SpeakerID(key: "spk-?")

    var isYou: Bool { key == SpeakerID.you.key }
}

/// Unified output of any transcription engine, before/after speaker attribution.
struct TranscriptSegment: Identifiable, Sendable, Equatable {
    let id: UUID
    let source: AudioSource
    var speaker: SpeakerID
    var text: String
    /// Offsets in seconds from session start (session clock, excludes pauses).
    var start: TimeInterval
    var end: TimeInterval
    var isFinal: Bool

    init(
        id: UUID = UUID(),
        source: AudioSource,
        speaker: SpeakerID,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}

/// Display info for a speaker in the live session.
struct SpeakerInfo: Identifiable, Sendable, Equatable {
    var id: SpeakerID { speakerID }
    let speakerID: SpeakerID
    var name: String
    var colorIndex: Int
}

/// A contiguous run of segments by the same speaker, for transcript display.
struct SpeakerTurn: Identifiable, Equatable {
    let id: UUID
    let speaker: SpeakerID
    var segments: [TranscriptSegment]

    var start: TimeInterval { segments.first?.start ?? 0 }
    var text: String {
        segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FormatStyle {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}
