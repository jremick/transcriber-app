import AppKit
import Combine
import SwiftData
import SwiftUI

enum SidebarSelection: Hashable {
    case live
    case session(PersistentIdentifier)
}

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @State private var selection: SidebarSelection? = .live

    var body: some View {
        @Bindable var settings = settings
        NavigationSplitView {
            SessionsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch selection {
            case .session(let id):
                SessionDetailView(sessionID: id)
            case .live, nil:
                LiveSessionView()
            }
        }
        .onChange(of: appState.recordingState) { _, newState in
            if newState == .recording { selection = .live }
        }
        .onChange(of: appState.lastFinishedSessionID) { _, finished in
            if let finished { selection = .session(finished) }
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { if !$0 { settings.hasCompletedOnboarding = true } }
        )) {
            OnboardingView()
        }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)) { _ in
            appState.handleSystemWillSleep()
        }
        .onAppear {
            // Dev hook: `defaults write dev.local.transcriber debugAutoStart -bool YES`
            if UserDefaults.standard.bool(forKey: "debugAutoStart"),
               appState.recordingState == .idle {
                appState.startSession()
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
    }
}

struct SessionsSidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Binding var selection: SidebarSelection?
    @Query(sort: \MeetingSession.startedAt, order: .reverse)
    private var sessions: [MeetingSession]
    @State private var searchText = ""

    private var filtered: [MeetingSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.notesMarkdown.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label {
                    Text(appState.recordingState.isActive ? "Live Session" : "New Session")
                } icon: {
                    Image(systemName: appState.recordingState == .recording
                        ? "record.circle.fill" : "plus.circle")
                        .foregroundStyle(appState.recordingState == .recording ? .red : .secondary)
                }
                .tag(SidebarSelection.live)
            }

            Section("History") {
                ForEach(filtered) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarSelection.session(session.persistentModelID))
                    .contextMenu {
                        Button("Export…") {
                            export(session)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            delete(session)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
        .navigationTitle("Transcriber")
    }

    private func delete(_ session: MeetingSession) {
        if selection == .session(session.persistentModelID) {
            selection = .live
        }
        modelContext.delete(session)
        do {
            try modelContext.save()
        } catch {
            appState.lastError = "Couldn't delete session: \(error.localizedDescription)"
        }
    }

    private func export(_ session: MeetingSession) {
        do {
            _ = try TranscriptExporter.exportWithPanel(session: session)
        } catch {
            appState.lastError = "Couldn't export transcript: \(error.localizedDescription)"
        }
    }
}
