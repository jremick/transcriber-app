import SwiftData
import SwiftUI

@main
struct TranscriberApp: App {
    @State private var appState: AppState
    private let modelContainer = PersistenceController.shared

    init() {
        let state = AppState(container: modelContainer)
        do {
            let repair = try SessionRecorder.repairUnfinishedSessions(in: modelContainer)
            if repair.closedSessions > 0 || repair.discardedEmptySessions > 0 {
                DebugDiag.log(
                    "repaired unfinished sessions: closed=\(repair.closedSessions) discarded=\(repair.discardedEmptySessions)"
                )
            }
        } catch {
            state.lastError = "Couldn't repair unfinished sessions: \(error.localizedDescription)"
            DebugDiag.log("unfinished session repair failed: \(error)")
        }
        state.configureDetection()
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        WindowGroup(id: WindowID.main) {
            MainWindowView()
                .environment(appState)
                .environment(appState.settings)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Session") {
                if appState.recordingState.isActive {
                    Button(appState.recordingState == .paused ? "Resume" : "Pause") {
                        appState.recordingState == .paused
                            ? appState.resumeSession()
                            : appState.pauseSession()
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Stop Transcribing") {
                        appState.stopSession()
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button("Start Transcribing") {
                        appState.startSession()
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                }
            }
        }

        MenuBarExtra {
            MenuBarExtraView()
                .environment(appState)
        } label: {
            Image(systemName: appState.recordingState == .recording
                ? "waveform.badge.microphone" : "waveform")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .environment(appState.settings)
        }
    }
}

enum WindowID {
    static let main = "main"
}
