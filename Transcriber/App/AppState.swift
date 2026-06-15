import Foundation
import OSLog
import Observation
import SwiftData

/// Central app coordinator: session lifecycle, live transcript state, and (in later
/// phases) the bridge between capture/transcription services and the UI.
@MainActor
@Observable
final class AppState {
    let settings: SettingsStore
    let capture = CaptureController()
    let detector = MeetingDetector()
    let notifications = NotificationService()
    let notesCoordinator = NotesCoordinator()
    private let recorder: SessionRecorder

    /// Set when a session finishes and persists; the sidebar selects it.
    private(set) var lastFinishedSessionID: PersistentIdentifier?

    enum SessionOrigin { case manual, detected }

    private(set) var recordingState: RecordingState = .idle
    private(set) var startedAt: Date?
    private(set) var currentSourceApp: String?
    private(set) var sessionOrigin: SessionOrigin = .manual
    var sessionTitle: String = ""

    private var engine: TranscriptionEngine?
    private let diarization = DiarizationService()
    private var eventsTask: Task<Void, Never>?
    private var intervalsTask: Task<Void, Never>?
    private var staleFlushTask: Task<Void, Never>?
    private var transcriptPipeline = TranscriptPipeline()
    /// 0...1 while the speech model downloads during `.preparing`.
    private(set) var prepareProgress: Double = 0

    /// Pause-aware session clock shared with the capture pipeline so all
    /// timestamps land on one timeline.
    let clock = SessionClock()

    /// Live transcript, grouped into speaker turns as segments finalize.
    private(set) var turns: [SpeakerTurn] = []
    /// In-progress (volatile) text per audio source, rendered as a low-opacity tail.
    private(set) var volatileText: [AudioSource: String] = [:]
    private(set) var speakers: [SpeakerID: SpeakerInfo] = [:]
    private(set) var notesMarkdown: String = ""
    private(set) var notesUpdatedAt: Date?

    /// Set while a detected meeting awaits the user's go-ahead; drives the
    /// in-app banner (works even when notifications are denied).
    private(set) var pendingDetection: MeetingDetector.DetectedMeeting?

    /// The engine actually running this session (may differ from settings
    /// after an automatic cloud→local fallback).
    private(set) var activeEngineKind: ASREngineChoice = .local
    /// Non-nil after an automatic fallback; shown as a dismissable banner.
    var fallbackNotice: String?

    var lastError: String?

    var captureStatus: CaptureStatus? {
        guard recordingState == .recording || recordingState == .paused else { return nil }
        return CaptureStatus.live(micUnavailable: capture.micUnavailable)
    }

    var navigationSubtitle: String {
        CaptureStatus.subtitle(
            recordingState: recordingState,
            sourceApp: currentSourceApp,
            micUnavailable: capture.micUnavailable
        )
    }

    init(
        settings: SettingsStore = SettingsStore(),
        container: ModelContainer = PersistenceController.shared
    ) {
        self.settings = settings
        self.recorder = SessionRecorder(container: container)
        recorder.snapshotProvider = { [weak self] in
            guard let self else { return nil }
            return SessionRecorder.Snapshot(
                title: sessionTitle,
                notesMarkdown: notesMarkdown,
                notesPrompt: settings.notesPrompt,
                segments: transcriptPipeline.segments,
                speakers: speakers
            )
        }
        recorder.onError = { [weak self] error in
            self?.lastError = "Couldn't save transcript: \(error.localizedDescription)"
        }
    }

    var elapsed: TimeInterval {
        recordingState.isActive ? clock.now() : 0
    }

    // MARK: - Meeting detection

    /// One-time wiring of detection + notifications; call at app launch.
    func configureDetection() {
        notifications.configure()
        notifications.onStartRequested = { [weak self] appName in
            guard let self, recordingState == .idle else { return }
            startSession(sourceApp: appName, origin: .detected)
        }

        detector.isEnabled = { [weak self] in
            self?.settings.autoDetectMeetings ?? false
        }
        detector.monitoredBundleIDs = { [weak self] in
            Set(self?.settings.monitoredBundleIDs ?? [])
        }
        detector.onMeetingStart = { [weak self] meeting in
            guard let self, recordingState == .idle else { return }
            DebugDiag.log("meeting detected: \(meeting.appName) tentative=\(meeting.isTentative) action=\(settings.detectionAction.rawValue)")
            switch settings.detectionAction {
            case .autoStart where !meeting.isTentative:
                startSession(sourceApp: meeting.appName, origin: .detected)
                notifications.postInfo(
                    title: "Transcribing \(meeting.appName)",
                    body: "Started automatically. Open Transcriber to watch live.")
            default:
                pendingDetection = meeting
                notifications.postMeetingDetected(
                    appName: meeting.appName, tentative: meeting.isTentative)
            }
        }
        detector.onMeetingEnd = { [weak self] meeting in
            guard let self else { return }
            pendingDetection = nil
            guard recordingState.isActive,
                  sessionOrigin == .detected,
                  settings.autoStopWhenMeetingEnds
            else { return }
            stopSession()
            notifications.postInfo(
                title: "Transcription saved",
                body: "The \(meeting.appName) meeting ended.")
        }
        detector.start()
        Task { _ = await notifications.requestAuthorization() }
        configureNotes()
    }

    private func configureNotes() {
        notesCoordinator.engineProvider = { [weak self] in
            guard let self else { return nil }
            switch settings.notesEngine {
            case .openAI:
                do {
                    return try KeychainStore.readAPIKey().map {
                        OpenAINotesEngine(apiKey: $0, model: settings.openAINotesModel)
                    }
                } catch {
                    lastError = error.localizedDescription
                    DebugDiag.log("keychain read failed for OpenAI notes: \(error.localizedDescription)")
                    return nil
                }
            case .appleOnDevice:
                return FoundationModelsNotesEngine()
            case .localExtractive:
                return LocalExtractiveNotesEngine()
            case .automatic:
                if FoundationModelsNotesEngine.availabilityIssue() == nil {
                    return FoundationModelsNotesEngine()
                }
                // Prefer cloud when explicitly configured, then keep notes local
                // with deterministic extraction when no key is available.
                do {
                    return try KeychainStore.readAPIKey().map {
                        OpenAINotesEngine(apiKey: $0, model: settings.openAINotesModel)
                    } ?? LocalExtractiveNotesEngine()
                } catch {
                    lastError = error.localizedDescription
                    DebugDiag.log("keychain read failed for OpenAI notes: \(error.localizedDescription)")
                    return LocalExtractiveNotesEngine()
                }
            }
        }
        notesCoordinator.promptProvider = { [weak self] in
            self?.settings.notesPrompt ?? DefaultPrompts.notes
        }
        notesCoordinator.cadenceProvider = { [weak self] in
            self?.settings.notesCadenceSeconds ?? 30
        }
        notesCoordinator.transcriptDelta = { [weak self] cursor in
            guard let self else { return ("", cursor) }
            let segments = transcriptPipeline.segments
            guard cursor < segments.count else { return ("", segments.count) }
            let lines = segments[cursor...].map { segment in
                "\(speakerInfo(for: segment.speaker).name): \(segment.text)"
            }
            return (lines.joined(separator: "\n"), segments.count)
        }
        notesCoordinator.currentNotes = { [weak self] in
            self?.notesMarkdown ?? ""
        }
        notesCoordinator.applyNotes = { [weak self] notes in
            self?.notesMarkdown = notes
            self?.notesUpdatedAt = .now
        }
    }

    // MARK: - Session lifecycle

    /// Pre-download speech + diarization models (onboarding).
    func predownloadModels(progress: @MainActor @escaping (Double) -> Void) async throws {
        let engine = LocalSpeechEngine()
        try await engine.prepare(
            locale: Locale(identifier: settings.transcriptionLocaleID),
            progress: progress
        )
        try await diarization.prepare()
    }

    /// Pause when the Mac sleeps; capture devices rarely survive sleep intact.
    func handleSystemWillSleep() {
        if recordingState == .recording {
            pauseSession()
            notifications.postInfo(
                title: "Transcription paused",
                body: "Your Mac went to sleep. Resume from the menu bar when you're back.")
        }
    }

    /// Accept the pending detected meeting (banner / menu bar action).
    func acceptPendingDetection() {
        guard let meeting = pendingDetection else { return }
        pendingDetection = nil
        startSession(sourceApp: meeting.appName, origin: .detected)
    }

    func dismissPendingDetection() {
        pendingDetection = nil
    }

    func startSession(sourceApp: String? = nil, origin: SessionOrigin = .manual) {
        guard recordingState == .idle else { return }
        recordingState = .preparing
        sessionOrigin = origin
        pendingDetection = nil
        currentSourceApp = sourceApp
        sessionTitle = Self.defaultTitle(for: .now, sourceApp: sourceApp)
        turns = []
        volatileText = [:]
        notesMarkdown = ""
        notesUpdatedAt = nil
        lastError = nil
        fallbackNotice = nil
        transcriptPipeline.resetForNewSession()
        syncTranscriptState()
        prepareProgress = 0

        Task {
            do {
                await diarization.resetForNewSession()
                let engine = try makeEngine()
                clock.start()
                try await runEngines(engine)
                startedAt = .now
                recordingState = .recording
                notesCoordinator.start()
                try recorder.begin(
                    title: sessionTitle,
                    sourceApp: currentSourceApp,
                    engine: activeEngineKind.rawValue
                )
            } catch {
                lastError = error.localizedDescription
                capture.stop()
                await engine?.stop()
                engine = nil
                recordingState = .idle
            }
        }
    }

    private func makeEngine() throws -> TranscriptionEngine {
        guard settings.asrEngine == .openAI else { return LocalSpeechEngine() }
        let key: String
        do {
            guard let storedKey = try KeychainStore.readAPIKey() else {
                throw TranscriptionError.notConfigured(
                    "OpenAI transcription is selected but no API key is set. Add one in Settings → Account, or switch to On-device.")
            }
            key = storedKey
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.notConfigured(error.localizedDescription)
        }
        return OpenAIRealtimeEngine(apiKey: key, model: settings.openAITranscriptionModel)
    }

    /// Prepare + start the given engine against fresh capture streams and
    /// re-arm all consumer tasks. Used at session start and for fallback.
    private func runEngines(_ engine: TranscriptionEngine) async throws {
        let log = Logger(subsystem: "dev.local.transcriber", category: "Session")
        self.engine = engine
        try await engine.prepare(
            locale: Locale(identifier: settings.transcriptionLocaleID)
        ) { [weak self] fraction in
            self?.prepareProgress = fraction
        }
        try await diarization.prepare()
        log.info("Engines prepared")

        let streams = try await capture.start(clock: clock)
        if capture.micUnavailable {
            log.warning("Capture degraded: microphone unavailable; system-only session")
        }
        let events = try await engine.start(
            micStream: streams.mic,
            systemStream: streams.system
        )
        let intervals = await diarization.run(stream: streams.systemDiarization)
        activeEngineKind = engine.kind
        log.info("Engines started (\(engine.kind.rawValue, privacy: .public))")

        eventsTask = Task { [weak self] in
            do {
                for try await event in events {
                    self?.apply(event)
                }
            } catch {
                self?.handleEngineFailure(error)
            }
        }
        intervalsTask = Task { [weak self] in
            for await interval in intervals {
                self?.applyInterval(interval)
            }
        }
        staleFlushTask?.cancel()
        staleFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.flushStaleAttributions()
            }
        }
    }

    /// Cloud engine died mid-session: switch to on-device without losing the
    /// transcript. The diarizer instance survives, so speaker identities hold.
    private func handleEngineFailure(_ error: Error) {
        guard recordingState.isActive else { return }
        guard activeEngineKind == .openAI else {
            lastError = error.localizedDescription
            return
        }
        DebugDiag.log("cloud engine failed, falling back to local: \(error)")
        Task {
            transcriptPipeline.flushAllAttributions()
            transcriptPipeline.resetTimeline()
            syncTranscriptState()
            capture.stop()
            await engine?.stop()
            await diarization.stop()
            eventsTask?.cancel()
            intervalsTask?.cancel()
            do {
                try await runEngines(LocalSpeechEngine())
                fallbackNotice =
                    "Cloud transcription is unavailable — switched to on-device. (\(error.localizedDescription))"
            } catch {
                lastError = "Transcription stopped: \(error.localizedDescription)"
                stopSession()
            }
        }
    }

    private func apply(_ event: EngineEvent) {
        transcriptPipeline.apply(event) { [capture] source, audioTime in
            capture.sessionTime(for: source, audioTime: audioTime)
        }
        syncTranscriptState()
    }

    private func applyInterval(_ interval: SpeakerInterval) {
        transcriptPipeline.applyInterval(interval)
        syncTranscriptState()
    }

    private func flushStaleAttributions() {
        transcriptPipeline.flushStaleAttributions()
        syncTranscriptState()
    }

    private func syncTranscriptState() {
        turns = transcriptPipeline.turns
        volatileText = transcriptPipeline.volatileText
        speakers = transcriptPipeline.speakers
    }

    func pauseSession() {
        guard recordingState == .recording else { return }
        clock.pause()
        capture.isPaused = true
        transcriptPipeline.clearVolatileText()
        syncTranscriptState()
        recordingState = .paused
    }

    func resumeSession() {
        guard recordingState == .paused else { return }
        clock.resume()
        capture.isPaused = false
        recordingState = .recording
    }

    func stopSession() {
        guard recordingState.isActive else { return }
        let finalDuration = clock.now()
        clock.stop()
        capture.stop()
        transcriptPipeline.clearVolatileText()
        syncTranscriptState()
        recordingState = .idle

        staleFlushTask?.cancel()
        staleFlushTask = nil
        Task {
            await engine?.stop()
            await diarization.stop()
            // Allow event/interval streams to drain tail results before teardown.
            try? await Task.sleep(for: .seconds(2))
            transcriptPipeline.flushAllAttributions()
            transcriptPipeline.clearVolatileText()
            syncTranscriptState()
            eventsTask?.cancel()
            intervalsTask?.cancel()
            eventsTask = nil
            intervalsTask = nil
            engine = nil
            await notesCoordinator.finish()
            do {
                lastFinishedSessionID = try recorder.finish(duration: finalDuration)
            } catch {
                lastError = "Couldn't save transcript: \(error.localizedDescription)"
                lastFinishedSessionID = nil
            }
        }
    }

    // MARK: - Speakers

    func speakerInfo(for id: SpeakerID) -> SpeakerInfo {
        transcriptPipeline.speakerInfo(for: id)
    }

    func renameSpeaker(_ id: SpeakerID, to name: String) {
        transcriptPipeline.renameSpeaker(id, to: name)
        syncTranscriptState()
    }

    static func defaultTitle(for date: Date, sourceApp: String?) -> String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        if let sourceApp { return "\(sourceApp) — \(time)" }
        return "Meeting — \(time)"
    }
}
