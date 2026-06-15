import Foundation
import SwiftData

@Model
final class MeetingSession {
    @Attribute(.unique) var id: UUID
    var title: String
    /// Display name of the meeting app that triggered detection (e.g. "Zoom"), if any.
    var sourceAppName: String?
    var startedAt: Date
    var endedAt: Date?
    /// Active recording time in seconds (pauses excluded).
    var duration: TimeInterval
    var notesMarkdown: String
    /// The notes prompt in effect when this session's notes were generated.
    var notesPromptUsed: String
    var asrEngineUsed: String

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegmentRecord.session)
    var segments: [TranscriptSegmentRecord]

    @Relationship(deleteRule: .cascade, inverse: \SpeakerRecord.session)
    var speakers: [SpeakerRecord]

    init(
        id: UUID = UUID(),
        title: String,
        sourceAppName: String? = nil,
        startedAt: Date = .now,
        asrEngineUsed: String = "local"
    ) {
        self.id = id
        self.title = title
        self.sourceAppName = sourceAppName
        self.startedAt = startedAt
        self.endedAt = nil
        self.duration = 0
        self.notesMarkdown = ""
        self.notesPromptUsed = ""
        self.asrEngineUsed = asrEngineUsed
        self.segments = []
        self.speakers = []
    }
}

@Model
final class TranscriptSegmentRecord {
    @Attribute(.unique) var id: UUID
    var session: MeetingSession?
    var speakerKey: String
    var source: String
    var text: String
    var startOffset: TimeInterval
    var endOffset: TimeInterval

    init(segment: TranscriptSegment) {
        self.id = segment.id
        self.speakerKey = segment.speaker.key
        self.source = segment.source.rawValue
        self.text = segment.text
        self.startOffset = segment.start
        self.endOffset = segment.end
    }
}

@Model
final class SpeakerRecord {
    @Attribute(.unique) var id: UUID
    var session: MeetingSession?
    var key: String
    var name: String
    var colorIndex: Int

    init(id: UUID = UUID(), key: String, name: String, colorIndex: Int) {
        self.id = id
        self.key = key
        self.name = name
        self.colorIndex = colorIndex
    }
}

enum PersistenceController {
    static let shared = makeContainer()

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([
            MeetingSession.self,
            TranscriptSegmentRecord.self,
            SpeakerRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }
}
