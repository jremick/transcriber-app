import Foundation
import SwiftData

/// Incrementally mirrors live session state into SwiftData. Runs a periodic
/// sync (default 5s) rather than per-event writes: diarization reassigns
/// speakers and echo suppression deletes segments after the fact, so an
/// upsert-style sync is both simpler and more correct. Volatile text never
/// gets here.
@MainActor
final class SessionRecorder {
    typealias SaveAction = () throws -> Void

    struct Snapshot {
        var title: String
        var notesMarkdown: String
        var notesPrompt: String
        var segments: [TranscriptSegment]
        var speakers: [SpeakerID: SpeakerInfo]
    }

    private let context: ModelContext
    private let save: SaveAction
    private var record: MeetingSession?
    private var syncTask: Task<Void, Never>?

    var snapshotProvider: () -> Snapshot? = { nil }
    var onError: (Error) -> Void = { _ in }

    init(container: ModelContainer, save: SaveAction? = nil) {
        let context = container.mainContext
        self.context = context
        self.save = save ?? { try context.save() }
    }

    func begin(title: String, sourceApp: String?, engine: String) throws {
        let session = MeetingSession(
            title: title, sourceAppName: sourceApp, asrEngineUsed: engine)
        context.insert(session)
        do {
            try save()
        } catch {
            context.delete(session)
            throw error
        }
        record = session

        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                do {
                    try self.sync()
                } catch {
                    self.onError(error)
                }
            }
        }
    }

    /// Final sync; deletes the record instead if the session produced nothing.
    /// Returns the persisted session's ID, or nil when discarded.
    @discardableResult
    func finish(duration: TimeInterval) throws -> PersistentIdentifier? {
        syncTask?.cancel()
        syncTask = nil
        defer { record = nil }
        try sync()
        guard let record else { return nil }
        if record.segments.isEmpty {
            context.delete(record)
            try save()
            return nil
        }
        record.endedAt = .now
        record.duration = duration
        try save()
        return record.persistentModelID
    }

    private func sync() throws {
        guard let record, let snapshot = snapshotProvider() else { return }
        record.title = snapshot.title
        record.notesMarkdown = snapshot.notesMarkdown
        record.notesPromptUsed = snapshot.notesPrompt

        var existing = Dictionary(
            uniqueKeysWithValues: record.segments.map { ($0.id, $0) })
        for segment in snapshot.segments {
            if let row = existing.removeValue(forKey: segment.id) {
                if row.text != segment.text { row.text = segment.text }
                if row.speakerKey != segment.speaker.key { row.speakerKey = segment.speaker.key }
                row.startOffset = segment.start
                row.endOffset = segment.end
            } else {
                let row = TranscriptSegmentRecord(segment: segment)
                row.session = record
                context.insert(row)
            }
        }
        // Anything left in `existing` was suppressed after being persisted.
        for (_, orphan) in existing {
            context.delete(orphan)
        }

        var existingSpeakers = Dictionary(
            uniqueKeysWithValues: record.speakers.map { ($0.key, $0) })
        for (id, info) in snapshot.speakers {
            if let row = existingSpeakers.removeValue(forKey: id.key) {
                if row.name != info.name { row.name = info.name }
                if row.colorIndex != info.colorIndex { row.colorIndex = info.colorIndex }
            } else {
                let row = SpeakerRecord(key: id.key, name: info.name, colorIndex: info.colorIndex)
                row.session = record
                context.insert(row)
            }
        }

        try save()
    }

    /// Close out sessions left open by a crash.
    struct RepairSummary: Equatable {
        var closedSessions = 0
        var discardedEmptySessions = 0
    }

    @discardableResult
    static func repairUnfinishedSessions(in container: ModelContainer) throws -> RepairSummary {
        let context = container.mainContext
        let descriptor = FetchDescriptor<MeetingSession>(
            predicate: #Predicate { $0.endedAt == nil })
        let orphans = try context.fetch(descriptor)
        var summary = RepairSummary()
        for session in orphans {
            if session.segments.isEmpty {
                context.delete(session)
                summary.discardedEmptySessions += 1
            } else {
                let lastEnd = session.segments.map(\.endOffset).max() ?? 0
                session.duration = lastEnd
                session.endedAt = session.startedAt.addingTimeInterval(lastEnd)
                summary.closedSessions += 1
            }
        }
        if !orphans.isEmpty {
            try context.save()
        }
        return summary
    }
}
