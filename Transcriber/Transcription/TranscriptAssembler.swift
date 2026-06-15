import Foundation

/// Pure transcript state: keeps finalized segments ordered by start time and
/// groups consecutive same-speaker segments into display turns.
struct TranscriptAssembler {
    private(set) var segments: [TranscriptSegment] = []

    /// Insert a finalized segment in start-time order.
    mutating func add(_ segment: TranscriptSegment) {
        let index = segments.lastIndex { $0.start <= segment.start }
            .map { segments.index(after: $0) } ?? segments.startIndex
        segments.insert(segment, at: index)
    }

    /// Re-assign the speaker of an existing segment (diarization attribution).
    mutating func reassign(segmentID: UUID, to speaker: SpeakerID) {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[i].speaker = speaker
    }

    /// Remove a segment (e.g. suppressed mic echo).
    mutating func remove(segmentID: UUID) {
        segments.removeAll { $0.id == segmentID }
    }

    /// Segments from `source` overlapping [start-window, end+window].
    func segments(
        from source: AudioSource,
        overlapping start: TimeInterval,
        _ end: TimeInterval,
        window: TimeInterval
    ) -> [TranscriptSegment] {
        segments.filter {
            $0.source == source && $0.start < end + window && $0.end > start - window
        }
    }

    /// Group into consecutive same-speaker turns. Turn IDs are stable: a turn
    /// reuses its first segment's UUID, so SwiftUI diffing stays cheap.
    func turns(maxGap: TimeInterval = 8) -> [SpeakerTurn] {
        var result: [SpeakerTurn] = []
        for segment in segments {
            if var last = result.last,
               last.speaker == segment.speaker,
               let lastEnd = last.segments.last?.end,
               segment.start - lastEnd <= maxGap {
                last.segments.append(segment)
                result[result.count - 1] = last
            } else {
                result.append(SpeakerTurn(
                    id: segment.id,
                    speaker: segment.speaker,
                    segments: [segment]
                ))
            }
        }
        return result
    }
}
