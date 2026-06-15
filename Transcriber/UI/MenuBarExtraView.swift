import SwiftUI

struct MenuBarExtraView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: appState.recordingState == .recording
                    ? "record.circle.fill" : "waveform")
                    .foregroundStyle(appState.recordingState == .recording ? .red : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.headline)
                    if appState.recordingState.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(FormatStyle.clock(appState.elapsed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            if let meeting = appState.pendingDetection {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2.fill")
                        .foregroundStyle(.tint)
                    Text("Meeting in \(meeting.appName)?")
                        .font(.callout)
                    Spacer()
                    Button("Start") {
                        appState.acceptPendingDetection()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if appState.recordingState.isActive {
                    Button(appState.recordingState == .paused ? "Resume" : "Pause") {
                        appState.recordingState == .paused
                            ? appState.resumeSession()
                            : appState.pauseSession()
                    }
                    Button("Stop") {
                        appState.stopSession()
                    }
                    .tint(.red)
                } else {
                    Button("Start Transcribing") {
                        appState.startSession()
                        openMain()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            Divider()

            HStack {
                Button("Open Transcriber") { openMain() }
                    .buttonStyle(.link)
                Spacer()
                SettingsLink()
                    .buttonStyle(.link)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var statusTitle: String {
        switch appState.recordingState {
        case .idle: "Not Recording"
        case .preparing: "Preparing…"
        case .recording: appState.currentSourceApp.map { "Capturing \($0)" } ?? "Recording"
        case .paused: "Paused"
        }
    }

    private func openMain() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}
