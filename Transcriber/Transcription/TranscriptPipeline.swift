import Foundation

/// Pure post-ASR transcript pipeline: applies engine events, diarizer intervals,
/// attribution, echo suppression, speaker registration, and turn assembly without
/// touching capture devices or persistence.
struct TranscriptPipeline {
    private var assembler = TranscriptAssembler()
    private var attributor = SpeakerAttributor()

    private(set) var speakers: [SpeakerID: SpeakerInfo] = [
        .you: SpeakerInfo(speakerID: .you, name: "You", colorIndex: 0)
    ]
    private(set) var volatileText: [AudioSource: String] = [:]

    /// Similarity above which a mic segment is considered speaker-bleed echo
    /// of a system segment (AEC isn't perfect).
    private let echoSimilarityThreshold = 0.7
    private let echoWindow: TimeInterval = 5

    var segments: [TranscriptSegment] { assembler.segments }
    var turns: [SpeakerTurn] { assembler.turns() }

    mutating func resetForNewSession() {
        assembler = TranscriptAssembler()
        attributor = SpeakerAttributor()
        speakers = [.you: SpeakerInfo(speakerID: .you, name: "You", colorIndex: 0)]
        volatileText = [:]
    }

    mutating func resetTimeline() {
        attributor.resetTimeline()
        volatileText = [:]
    }

    mutating func clearVolatileText() {
        volatileText = [:]
    }

    mutating func apply(
        _ event: EngineEvent,
        sessionTime: (AudioSource, TimeInterval) -> TimeInterval = { _, time in time }
    ) {
        switch event {
        case .volatile(let source, let text):
            volatileText[source] = text
        case .final(var segment):
            // Attribution and dedup operate on audio time; display and
            // persistence use session time.
            let audioStart = segment.start
            let audioEnd = segment.end
            segment.start = sessionTime(segment.source, audioStart)
            segment.end = sessionTime(segment.source, audioEnd)

            switch segment.source {
            case .microphone:
                guard !isMicEcho(segment) else { return }
                registerSpeakerIfNeeded(segment.speaker)
                assembler.add(segment)
            case .system:
                registerSpeakerIfNeeded(segment.speaker)
                assembler.add(segment)
                suppressEchoes(of: segment)
                let resolutions = attributor.enqueue(
                    segmentID: segment.id, start: audioStart, end: audioEnd)
                applyResolutions(resolutions)
            }
        }
    }

    mutating func applyInterval(_ interval: SpeakerInterval) {
        applyResolutions(attributor.addInterval(interval))
    }

    mutating func flushStaleAttributions() {
        applyResolutions(attributor.flushStale())
    }

    mutating func flushAllAttributions() {
        applyResolutions(attributor.flushAll())
    }

    func speakerInfo(for id: SpeakerID) -> SpeakerInfo {
        speakers[id] ?? SpeakerInfo(
            speakerID: id,
            name: id.isYou ? "You" : "Speaker",
            colorIndex: 0
        )
    }

    mutating func renameSpeaker(_ id: SpeakerID, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        speakers[id]?.name = name
    }

    /// True when a freshly-final mic segment is just the speakers bleeding
    /// into the microphone (same words as a nearby system segment).
    private func isMicEcho(_ segment: TranscriptSegment) -> Bool {
        let nearby = assembler.segments(
            from: .system, overlapping: segment.start, segment.end, window: echoWindow)
        return nearby.contains {
            TextSimilarity.similarity($0.text, segment.text) >= echoSimilarityThreshold
        }
    }

    /// Remove already-displayed mic segments that duplicate a system segment
    /// which finalized later.
    private mutating func suppressEchoes(of systemSegment: TranscriptSegment) {
        let micNearby = assembler.segments(
            from: .microphone,
            overlapping: systemSegment.start, systemSegment.end,
            window: echoWindow)
        for mic in micNearby
        where TextSimilarity.similarity(mic.text, systemSegment.text) >= echoSimilarityThreshold {
            assembler.remove(segmentID: mic.id)
        }
    }

    private mutating func applyResolutions(_ resolutions: [SpeakerAttributor.Resolution]) {
        guard !resolutions.isEmpty else { return }
        for resolution in resolutions {
            let speaker = SpeakerID.remote(resolution.cluster ?? 0)
            DebugDiag.log("attrib segment \(resolution.segmentID.uuidString.prefix(8)) -> cluster \(resolution.cluster.map(String.init) ?? "nil(fallback 0)")")
            registerSpeakerIfNeeded(speaker)
            assembler.reassign(segmentID: resolution.segmentID, to: speaker)
        }
    }

    private mutating func registerSpeakerIfNeeded(_ id: SpeakerID) {
        guard speakers[id] == nil else { return }
        if id == .unattributed {
            speakers[id] = SpeakerInfo(speakerID: id, name: "Speaker", colorIndex: 1)
            return
        }
        let remoteCount = speakers.count { !$0.key.isYou && $0.key != .unattributed }
        speakers[id] = SpeakerInfo(
            speakerID: id,
            name: "Speaker \(remoteCount + 1)",
            colorIndex: remoteCount + 1
        )
    }
}
