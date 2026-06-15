import Foundation

/// Engine-agnostic merge of ASR segments with the diarizer's speaker timeline.
/// Both sides speak "system fed-audio time", so attribution is a pure
/// time-overlap problem. Segments whose audio the diarizer hasn't finalized
/// yet are queued and resolved when the diarizer catches up (or goes stale).
struct SpeakerAttributor {
    struct Resolution: Equatable {
        let segmentID: UUID
        /// Diarizer cluster index; nil when no interval overlaps (caller picks fallback).
        let cluster: Int?
    }

    private struct Pending {
        let id: UUID
        let start: TimeInterval
        let end: TimeInterval
        let enqueuedAt: Date
    }

    private(set) var intervals: [SpeakerInterval] = []
    /// How far (in audio time) the diarizer has finalized.
    private(set) var watermark: TimeInterval = 0
    private var pending: [Pending] = []

    /// Tolerance when deciding the diarizer has "covered" a segment's end.
    private let coverageSlack: TimeInterval = 0.25
    /// Wall-clock age after which a pending segment is force-resolved.
    private let maxPendingAge: TimeInterval = 5

    mutating func addInterval(_ interval: SpeakerInterval, now: Date = .now) -> [Resolution] {
        // Merge with the previous interval when the diarizer extends a turn.
        if let last = intervals.last,
           last.clusterIndex == interval.clusterIndex,
           interval.start - last.end < 0.5,
           interval.end > last.end {
            intervals[intervals.count - 1] = SpeakerInterval(
                clusterIndex: last.clusterIndex, start: last.start, end: interval.end)
        } else {
            intervals.append(interval)
        }
        watermark = max(watermark, interval.end)
        return resolveReady(now: now)
    }

    /// Queue a system ASR segment; returns resolutions that are ready now.
    mutating func enqueue(
        segmentID: UUID, start: TimeInterval, end: TimeInterval, now: Date = .now
    ) -> [Resolution] {
        pending.append(Pending(id: segmentID, start: start, end: end, enqueuedAt: now))
        return resolveReady(now: now)
    }

    /// Force-resolve anything stale (call periodically).
    mutating func flushStale(now: Date = .now) -> [Resolution] {
        resolveReady(now: now)
    }

    /// Resolve every pending segment immediately (engine switch / shutdown).
    mutating func flushAll() -> [Resolution] {
        let resolutions = pending.map {
            Resolution(segmentID: $0.id, cluster: bestCluster(start: $0.start, end: $0.end))
        }
        pending = []
        return resolutions
    }

    /// Drop all timeline state. Used when the audio timeline restarts
    /// (mid-session engine switch); cluster indices remain comparable because
    /// the diarizer itself is kept alive.
    mutating func resetTimeline() {
        intervals = []
        watermark = 0
        pending = []
    }

    private mutating func resolveReady(now: Date) -> [Resolution] {
        var done: [Resolution] = []
        var remaining: [Pending] = []
        for p in pending {
            let covered = watermark + coverageSlack >= p.end
            let stale = now.timeIntervalSince(p.enqueuedAt) > maxPendingAge
            if covered || stale {
                done.append(Resolution(segmentID: p.id, cluster: bestCluster(start: p.start, end: p.end)))
            } else {
                remaining.append(p)
            }
        }
        pending = remaining
        return done
    }

    /// Highest-overlap cluster for a time range; falls back to the nearest
    /// interval within 3 seconds.
    func bestCluster(start: TimeInterval, end: TimeInterval) -> Int? {
        var overlapByCluster: [Int: TimeInterval] = [:]
        for interval in intervals {
            let overlap = min(end, interval.end) - max(start, interval.start)
            if overlap > 0 {
                overlapByCluster[interval.clusterIndex, default: 0] += overlap
            }
        }
        if let best = overlapByCluster.max(by: { $0.value < $1.value }) {
            return best.key
        }

        var nearest: (cluster: Int, distance: TimeInterval)?
        for interval in intervals {
            let distance = interval.end < start
                ? start - interval.end
                : (interval.start > end ? interval.start - end : 0)
            if distance <= 3, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (interval.clusterIndex, distance)
            }
        }
        return nearest?.cluster
    }
}

/// Word-level text similarity used to drop microphone echo of system audio
/// (imperfect AEC means the mic can transcribe what the speakers played).
enum TextSimilarity {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Max of word-set Jaccard, word-set containment, and normalized
    /// character-level similarity (catches ASR variance like
    /// "login check" vs "logging check" on short utterances), 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let tokensA = tokens(a)
        let tokensB = tokens(b)
        let setA = Set(tokensA)
        let setB = Set(tokensB)
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = Double(setA.intersection(setB).count)
        let jaccard = intersection / Double(setA.union(setB).count)
        let containment = intersection / Double(min(setA.count, setB.count))

        let charsA = tokensA.joined()
        let charsB = tokensB.joined()
        let charRatio = 1.0 - Double(levenshtein(charsA, charsB))
            / Double(max(charsA.count, charsB.count, 1))

        return max(jaccard, containment, charRatio)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a.utf8)
        let bChars = Array(b.utf8)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        // Cap cost on pathological inputs; echo checks compare short texts.
        if aChars.count * bChars.count > 200_000 {
            return abs(aChars.count - bChars.count)
        }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
