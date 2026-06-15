import Foundation
import Testing
@testable import Transcriber

struct SpeakerAttributorTests {
    @Test func attributesByOverlap() {
        var attributor = SpeakerAttributor()
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 0, start: 0, end: 5))
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 1, start: 5, end: 12))

        let id = UUID()
        let resolutions = attributor.enqueue(segmentID: id, start: 6, end: 10)
        #expect(resolutions == [SpeakerAttributor.Resolution(segmentID: id, cluster: 1)])
    }

    @Test func pendsUntilWatermarkCovers() {
        var attributor = SpeakerAttributor()
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 0, start: 0, end: 4))

        let id = UUID()
        // Segment ends at 8s but diarizer has only finalized through 4s.
        #expect(attributor.enqueue(segmentID: id, start: 2, end: 8).isEmpty)

        let resolutions = attributor.addInterval(SpeakerInterval(clusterIndex: 0, start: 4, end: 9))
        #expect(resolutions.count == 1)
        #expect(resolutions[0].cluster == 0)
    }

    @Test func staleSegmentsForceResolve() {
        var attributor = SpeakerAttributor()
        let id = UUID()
        let past = Date(timeIntervalSinceNow: -10)
        #expect(attributor.enqueue(segmentID: id, start: 0, end: 5, now: past).isEmpty)
        let resolutions = attributor.flushStale()
        #expect(resolutions.count == 1)
        #expect(resolutions[0].cluster == nil)
    }

    @Test func nearestIntervalFallback() {
        var attributor = SpeakerAttributor()
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 2, start: 0, end: 4))
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 3, start: 20, end: 30))
        // No overlap; nearest within 3s is cluster 2 (gap of 1s).
        #expect(attributor.bestCluster(start: 5, end: 6) == 2)
        // Too far from anything.
        #expect(attributor.bestCluster(start: 10, end: 12) == nil)
    }

    @Test func mergesAdjacentSameClusterIntervals() {
        var attributor = SpeakerAttributor()
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 0, start: 0, end: 2))
        _ = attributor.addInterval(SpeakerInterval(clusterIndex: 0, start: 2.1, end: 5))
        #expect(attributor.intervals.count == 1)
        #expect(attributor.intervals[0].end == 5)
    }
}

struct TextSimilarityTests {
    @Test func identicalTextsMatch() {
        #expect(TextSimilarity.similarity(
            "The quick brown fox jumps over the lazy dog.",
            "the quick brown fox jumps over the lazy dog") > 0.95)
    }

    @Test func echoWithASRNoiseStillMatches() {
        let system = "This sentence is spoken roughly 15 seconds into the session."
        let mic = "This sentence has spoken roughly 15 seconds into the session."
        #expect(TextSimilarity.similarity(system, mic) > 0.7)
    }

    @Test func differentContentDoesNotMatch() {
        #expect(TextSimilarity.similarity(
            "Let's review the quarterly budget numbers today",
            "I think we should ship the new onboarding flow") < 0.3)
    }

    @Test func emptyStringsAreZero() {
        #expect(TextSimilarity.similarity("", "anything") == 0)
    }
}

struct TranscriptAssemblerTests {
    private func segment(
        _ text: String, source: AudioSource = .system,
        speaker: SpeakerID = .unattributed,
        start: TimeInterval, end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(source: source, speaker: speaker, text: text, start: start, end: end, isFinal: true)
    }

    @Test func keepsSegmentsOrdered() {
        var assembler = TranscriptAssembler()
        assembler.add(segment("b", start: 5, end: 6))
        assembler.add(segment("a", start: 1, end: 2))
        assembler.add(segment("c", start: 8, end: 9))
        #expect(assembler.segments.map(\.text) == ["a", "b", "c"])
    }

    @Test func groupsConsecutiveSameSpeaker() {
        var assembler = TranscriptAssembler()
        assembler.add(segment("hello", speaker: .remote(0), start: 0, end: 2))
        assembler.add(segment("world", speaker: .remote(0), start: 2.5, end: 4))
        assembler.add(segment("hi", source: .microphone, speaker: .you, start: 5, end: 6))
        let turns = assembler.turns()
        #expect(turns.count == 2)
        #expect(turns[0].text == "hello world")
        #expect(turns[1].speaker == .you)
    }

    @Test func gapBreaksTurn() {
        var assembler = TranscriptAssembler()
        assembler.add(segment("first", source: .microphone, speaker: .you, start: 0, end: 2))
        assembler.add(segment("second", source: .microphone, speaker: .you, start: 30, end: 32))
        #expect(assembler.turns(maxGap: 8).count == 2)
    }

    @Test func reassignAndRemove() {
        var assembler = TranscriptAssembler()
        let seg = segment("hello", start: 0, end: 2)
        assembler.add(seg)
        assembler.reassign(segmentID: seg.id, to: .remote(3))
        #expect(assembler.segments[0].speaker == .remote(3))
        assembler.remove(segmentID: seg.id)
        #expect(assembler.segments.isEmpty)
    }
}

struct TimelineMapperTests {
    @Test func continuousStreamMapsIdentity() {
        let mapper = TimelineMapper()
        // 10 chunks of 0.1s arriving in real time from session start.
        for i in 0..<10 {
            mapper.record(duration: 0.1, at: Double(i + 1) * 0.1)
        }
        #expect(abs(mapper.sessionTime(forAudioTime: 0.5) - 0.5) < 0.05)
    }

    @Test func gappedStreamShiftsLaterAudio() {
        let mapper = TimelineMapper()
        // 1s of audio at session start...
        mapper.record(duration: 1.0, at: 1.0)
        // ...then silence until session t=10, when another 1s chunk arrives.
        mapper.record(duration: 1.0, at: 11.0)
        // Audio time 1.5 is inside the second chunk → session ≈ 10.5.
        #expect(abs(mapper.sessionTime(forAudioTime: 1.5) - 10.5) < 0.1)
    }
}
