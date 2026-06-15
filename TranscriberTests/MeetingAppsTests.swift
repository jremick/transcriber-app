import Foundation
import Testing
@testable import Transcriber

struct MeetingAppsTests {
    @Test func chromeHelperCanonicalizesToChrome() {
        #expect(MeetingApps.canonicalBundleID(for: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(MeetingApps.browserBundleIDs.contains(
            MeetingApps.canonicalBundleID(for: "com.google.Chrome.helper")))
    }

    @Test func canonicalBundleIDLeavesMainAppUntouched() {
        #expect(MeetingApps.canonicalBundleID(for: "com.google.Chrome") == "com.google.Chrome")
        #expect(MeetingApps.canonicalBundleID(for: "us.zoom.xos") == "us.zoom.xos")
    }
}

@MainActor
struct MeetingDetectorTests {
    @Test func startsAfterDebounce() async throws {
        let active: Set<String> = ["com.google.Chrome.helper"]
        var now = Date(timeIntervalSince1970: 0)
        let detector = makeDetector(active: { active }, now: { now })
        var starts: [MeetingDetector.DetectedMeeting] = []
        detector.onMeetingStart = { starts.append($0) }

        await detector.pollOnce()
        #expect(starts.isEmpty)
        #expect(detector.current == nil)

        now = now.addingTimeInterval(1.9)
        await detector.pollOnce()
        #expect(starts.isEmpty)

        now = now.addingTimeInterval(0.2)
        await detector.pollOnce()

        let meeting = try #require(starts.first)
        #expect(starts.count == 1)
        #expect(meeting.bundleID == "com.google.Chrome")
        #expect(meeting.appName == "Chrome")
        #expect(meeting.isTentative)
        #expect(detector.current == meeting)
    }

    @Test func endsAfterGraceOnlyWhenSignalStaysAbsent() async throws {
        var active: Set<String> = ["com.google.Chrome.helper"]
        var now = Date(timeIntervalSince1970: 0)
        let detector = makeDetector(active: { active }, now: { now }, endGrace: 5)
        var starts: [MeetingDetector.DetectedMeeting] = []
        var ends: [MeetingDetector.DetectedMeeting] = []
        detector.onMeetingStart = { starts.append($0) }
        detector.onMeetingEnd = { ends.append($0) }

        await detector.pollOnce()
        now = now.addingTimeInterval(2.1)
        await detector.pollOnce()
        let started = try #require(starts.first)

        active = []
        now = now.addingTimeInterval(0.1)
        await detector.pollOnce()
        #expect(ends.isEmpty)
        #expect(detector.current == started)

        now = now.addingTimeInterval(4.9)
        await detector.pollOnce()
        #expect(ends.isEmpty)

        active = ["com.google.Chrome.helper"]
        await detector.pollOnce()
        #expect(ends.isEmpty)

        active = []
        now = now.addingTimeInterval(0.1)
        await detector.pollOnce()
        now = now.addingTimeInterval(5.1)
        await detector.pollOnce()

        #expect(ends == [started])
        #expect(detector.current == nil)
    }

    @Test func switchesToDedicatedMeetingAppWithoutSecondStart() async throws {
        var active: Set<String> = ["com.google.Chrome.helper"]
        var now = Date(timeIntervalSince1970: 0)
        let detector = makeDetector(active: { active }, now: { now })
        var starts: [MeetingDetector.DetectedMeeting] = []
        detector.onMeetingStart = { starts.append($0) }

        await detector.pollOnce()
        now = now.addingTimeInterval(2.1)
        await detector.pollOnce()

        active = ["com.google.Chrome.helper", "us.zoom.xos"]
        await detector.pollOnce()

        let current = try #require(detector.current)
        #expect(starts.count == 1)
        #expect(current.bundleID == "us.zoom.xos")
        #expect(current.appName == "Zoom")
        #expect(!current.isTentative)
    }

    private func makeDetector(
        active: @escaping () -> Set<String>,
        now: @escaping () -> Date,
        endGrace: TimeInterval = 20
    ) -> MeetingDetector {
        let detector = MeetingDetector(
            activeInputBundleIDs: { active() },
            now: now,
            startDebounce: 2,
            endGrace: endGrace
        )
        detector.isEnabled = { true }
        detector.monitoredBundleIDs = {
            ["com.google.Chrome", "us.zoom.xos"]
        }
        return detector
    }
}
