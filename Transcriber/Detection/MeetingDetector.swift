import Foundation
import Observation

/// Watches mic usage by other apps and decides when a meeting starts/ends.
///
/// State machine: idle → candidate (debounce) → active → ending (grace) → idle.
/// Detection events fire via callbacks; AppState decides what to do with them
/// (prompt notification vs. auto-start, auto-stop).
@MainActor
@Observable
final class MeetingDetector {
    struct DetectedMeeting: Equatable {
        let bundleID: String
        let appName: String
        /// Browsers give a weaker signal — any website could be using the mic.
        let isTentative: Bool
    }

    private enum State: Equatable {
        case idle
        case candidate(DetectedMeeting, since: Date)
        case active(DetectedMeeting)
        case ending(DetectedMeeting, since: Date)
    }

    private let activeInputBundleIDs: () async -> Set<String>
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    private var state: State = .idle

    private let pollInterval: Duration
    private let startDebounce: TimeInterval
    private let endGrace: TimeInterval

    /// Currently detected meeting, if any (for UI display).
    private(set) var current: DetectedMeeting?

    var onMeetingStart: ((DetectedMeeting) -> Void)?
    var onMeetingEnd: ((DetectedMeeting) -> Void)?
    /// Settings provider, injected by AppState.
    var monitoredBundleIDs: () -> Set<String> = { [] }
    var isEnabled: () -> Bool = { false }

    init(
        activeInputBundleIDs: (() async -> Set<String>)? = nil,
        now: @escaping () -> Date = Date.init,
        pollInterval: Duration = .seconds(2),
        startDebounce: TimeInterval = 2,
        endGrace: TimeInterval = 20
    ) {
        if let activeInputBundleIDs {
            self.activeInputBundleIDs = activeInputBundleIDs
        } else {
            let monitor = AudioProcessMonitor()
            self.activeInputBundleIDs = { await monitor.activeInputBundleIDs() }
        }
        self.now = now
        self.pollInterval = pollInterval
        self.startDebounce = startDebounce
        self.endGrace = endGrace
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                guard let pollInterval = self?.pollInterval else { return }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        state = .idle
        current = nil
    }

    func pollOnce() async {
        await poll()
    }

    private var lastLoggedActive: Set<String> = []

    private func poll() async {
        guard isEnabled() else {
            state = .idle
            current = nil
            return
        }
        let active = await activeInputBundleIDs()
        let canonicalActive = Set(active.map(MeetingApps.canonicalBundleID(for:)))
        if active != lastLoggedActive {
            lastLoggedActive = active
            let raw = active.sorted().joined(separator: ", ")
            let canonical = canonicalActive.sorted().joined(separator: ", ")
            DebugDiag.log("mic-active apps: \(raw) canonical: \(canonical)")
        }
        let monitored = monitoredBundleIDs()
        let matches = canonicalActive.intersection(monitored)
        // Prefer dedicated meeting apps over browsers (weaker signal).
        let best = matches.min { a, b in
            let aBrowser = MeetingApps.browserBundleIDs.contains(a)
            let bBrowser = MeetingApps.browserBundleIDs.contains(b)
            if aBrowser != bBrowser { return !aBrowser }
            return a < b
        }
        transition(detected: best.map(Self.meeting(for:)))
    }

    private func transition(detected: DetectedMeeting?) {
        let timestamp = now()
        switch (state, detected) {
        case (.idle, .some(let meeting)):
            state = .candidate(meeting, since: timestamp)

        case (.candidate(let meeting, let since), .some(let nowMeeting)):
            if meeting.bundleID != nowMeeting.bundleID {
                state = .candidate(nowMeeting, since: timestamp)
            } else if timestamp.timeIntervalSince(since) >= startDebounce {
                state = .active(meeting)
                current = meeting
                onMeetingStart?(meeting)
            }

        case (.candidate, .none):
            state = .idle

        case (.active(let meeting), .none):
            state = .ending(meeting, since: timestamp)

        case (.active(let meeting), .some(let nowMeeting))
            where meeting.bundleID != nowMeeting.bundleID:
            // A different (better) app took over; treat as same ongoing meeting.
            state = .active(nowMeeting)
            current = nowMeeting

        case (.ending(let meeting, _), .some(let nowMeeting))
            where meeting.bundleID == nowMeeting.bundleID:
            state = .active(meeting)

        case (.ending(let meeting, let since), .none):
            if timestamp.timeIntervalSince(since) >= endGrace {
                state = .idle
                current = nil
                onMeetingEnd?(meeting)
            }

        default:
            break
        }
    }

    private static func meeting(for bundleID: String) -> DetectedMeeting {
        let isBrowser = MeetingApps.browserBundleIDs.contains(bundleID)
        var name = MeetingApps.displayName(forBundleID: bundleID)
        if let suffixRange = name.range(of: " (Meet?)") {
            name.removeSubrange(suffixRange)
        }
        return DetectedMeeting(bundleID: bundleID, appName: name, isTentative: isBrowser)
    }
}
