import Foundation
import os

/// Pause-aware session clock, readable from any thread. `now()` returns the
/// active (un-paused) seconds since `start()`.
final class SessionClock: Sendable {
    private struct State {
        var accumulated: TimeInterval = 0
        var resumedAt: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() {
        state.withLock { $0 = State(accumulated: 0, resumedAt: .now) }
    }

    func pause() {
        state.withLock {
            if let resumed = $0.resumedAt {
                $0.accumulated += Date.now.timeIntervalSince(resumed)
            }
            $0.resumedAt = nil
        }
    }

    func resume() {
        state.withLock {
            if $0.resumedAt == nil { $0.resumedAt = .now }
        }
    }

    func stop() {
        pause()
    }

    func now() -> TimeInterval {
        state.withLock {
            $0.accumulated + ($0.resumedAt.map { Date.now.timeIntervalSince($0) } ?? 0)
        }
    }
}

/// Maps a stream's cumulative fed-audio time to session time. Capture streams
/// can have gaps (the system tap emits nothing while no audio plays), so ASR
/// timestamps — which count fed audio — drift from the session clock. One
/// anchor is recorded per gap; lookups interpolate from the preceding anchor.
final class TimelineMapper: Sendable {
    private struct State {
        var anchors: [(audio: TimeInterval, session: TimeInterval)] = []
        var cumulativeAudio: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Gap larger than this between expected and actual session time starts a new anchor.
    private let gapTolerance: TimeInterval = 0.5

    /// Record a chunk of `duration` seconds arriving at `sessionTime`.
    func record(duration: TimeInterval, at sessionTime: TimeInterval) {
        state.withLock { s in
            let chunkStartSession = sessionTime - duration
            if let last = s.anchors.last {
                let expectedSession = last.session + (s.cumulativeAudio - last.audio)
                if chunkStartSession - expectedSession > gapTolerance {
                    s.anchors.append((audio: s.cumulativeAudio, session: chunkStartSession))
                }
            } else {
                s.anchors.append((audio: 0, session: max(0, chunkStartSession)))
            }
            s.cumulativeAudio += duration
        }
    }

    /// Convert a fed-audio timestamp to session time.
    func sessionTime(forAudioTime audio: TimeInterval) -> TimeInterval {
        state.withLock { s in
            guard !s.anchors.isEmpty else { return audio }
            var candidate = s.anchors[0]
            for anchor in s.anchors {
                if anchor.audio <= audio { candidate = anchor } else { break }
            }
            return candidate.session + (audio - candidate.audio)
        }
    }
}
