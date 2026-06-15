import SwiftUI

/// The live two-column session view: transcript (left) and key notes (right).
struct LiveSessionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            if let meeting = appState.pendingDetection {
                DetectionBanner(meeting: meeting)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let notice = appState.fallbackNotice {
                HStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") {
                        appState.fallbackNotice = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { Divider() }
            }
            if let status = appState.captureStatus {
                CaptureStatusBanner(status: status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HSplitView {
                TranscriptColumnView()
                    .frame(minWidth: 380, idealWidth: 620)
                    .layoutPriority(1)
                NotesColumnView()
                    .frame(minWidth: 300, idealWidth: 420)
            }
        }
        .animation(.snappy(duration: 0.25), value: appState.pendingDetection)
        .animation(.snappy(duration: 0.25), value: appState.captureStatus)
        .overlay {
            if appState.recordingState == .preparing {
                VStack(spacing: 12) {
                    ProgressView(value: appState.prepareProgress > 0 ? appState.prepareProgress : nil)
                        .progressViewStyle(.circular)
                    Text(appState.prepareProgress > 0 && appState.prepareProgress < 1
                        ? "Downloading speech model… \(Int(appState.prepareProgress * 100))%"
                        : "Preparing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .modifier(LiveTitleModifier(
            isActive: appState.recordingState.isActive,
            title: $appState.sessionTitle))
        .navigationSubtitle(appState.navigationSubtitle)
        .toolbar { SessionToolbar() }
    }
}

/// Editable window title while recording (click to rename the session).
struct LiveTitleModifier: ViewModifier {
    let isActive: Bool
    @Binding var title: String

    func body(content: Content) -> some View {
        if isActive {
            content.navigationTitle($title)
        } else {
            content.navigationTitle("Transcriber")
        }
    }
}

struct DetectionBanner: View {
    @Environment(AppState.self) private var appState
    let meeting: MeetingDetector.DetectedMeeting

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.isTentative
                    ? "Possible meeting in \(meeting.appName)"
                    : "Meeting detected in \(meeting.appName)")
                    .font(.callout.weight(.semibold))
                Text("Start transcribing?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now") {
                appState.dismissPendingDetection()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Dismiss meeting detection")
            Button("Start Transcribing") {
                appState.acceptPendingDetection()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start transcribing detected meeting")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct CaptureStatusBanner: View {
    let status: CaptureStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.systemImage)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(.callout.weight(.semibold))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

struct SessionToolbar: ToolbarContent {
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if appState.recordingState.isActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(FormatStyle.clock(appState.elapsed))
                        .clockStyle()
                        .foregroundStyle(appState.recordingState == .paused ? .secondary : .primary)
                }
                .accessibilityLabel("Session runtime")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if appState.recordingState.isActive {
                LevelMeterView()
            }
            engineBadge

            if appState.recordingState.isActive {
                Button {
                    appState.recordingState == .paused
                        ? appState.resumeSession()
                        : appState.pauseSession()
                } label: {
                    Label(
                        appState.recordingState == .paused ? "Resume" : "Pause",
                        systemImage: appState.recordingState == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .help(appState.recordingState == .paused ? "Resume transcription" : "Pause transcription")

                Button {
                    appState.stopSession()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .help("Stop and save this session")
            } else {
                Button {
                    appState.startSession()
                } label: {
                    Label("Start", systemImage: "record.circle")
                }
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.command])
                .help("Start transcribing")
            }
        }
    }

    private var engineBadge: some View {
        let kind = appState.recordingState.isActive
            ? appState.activeEngineKind
            : appState.settings.asrEngine
        return Text(kind == .local ? "On-device" : "OpenAI")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Transcription engine")
    }
}
