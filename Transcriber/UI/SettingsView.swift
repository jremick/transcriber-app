import AVFoundation
import Speech
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            NotesSettingsView()
                .tabItem { Label("Notes", systemImage: "sparkles") }
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "key") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Meeting Detection") {
                Toggle("Detect when a meeting starts", isOn: $settings.autoDetectMeetings)
                Picker("When a meeting is detected", selection: $settings.detectionAction) {
                    ForEach(MeetingDetectionAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .disabled(!settings.autoDetectMeetings)
                Toggle("Stop when the meeting ends", isOn: $settings.autoStopWhenMeetingEnds)
                    .disabled(!settings.autoDetectMeetings)
            }

            Section("Monitored Apps") {
                MonitoredAppsList()
            }

            Section("Permissions") {
                PermissionsHealthView()
            }

            Section("Diagnostics") {
                DebugArtifactsView()
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

struct PermissionsHealthView: View {
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notifStatus: UNAuthorizationStatus?

    var body: some View {
        permissionRow(
            title: "Microphone",
            ok: micStatus == .authorized,
            detail: micStatus == .authorized ? "Granted" : "Not granted",
            pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        permissionRow(
            title: "System Audio Recording",
            ok: nil,
            detail: "macOS asks on first session; manage in Privacy & Security",
            pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        )
        permissionRow(
            title: "Notifications",
            ok: notifStatus.map { $0 == .authorized || $0 == .provisional },
            detail: notificationsDetail,
            pane: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        .task {
            notifStatus = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var notificationsDetail: String {
        switch notifStatus {
        case .authorized, .provisional: "Enabled"
        case .denied: "Denied — enable in System Settings"
        default: "Not requested yet"
        }
    }

    private func permissionRow(
        title: String, ok: Bool?, detail: String, pane: String
    ) -> some View {
        HStack {
            Image(systemName: ok == true
                ? "checkmark.circle.fill"
                : (ok == false ? "xmark.circle.fill" : "info.circle.fill"))
                .foregroundStyle(ok == true ? .green : (ok == false ? .red : .secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: pane) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}

struct DebugArtifactsView: View {
    @State private var audioDumpEnabled = UserDefaults.standard.bool(forKey: "debugAudioDump")
    @State private var diagnosticsEnabled = UserDefaults.standard.bool(forKey: "debugDiag")
    @State private var debugFileCount = 0
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                title: "Audio dumps",
                enabled: audioDumpEnabled,
                detail: audioDumpEnabled
                    ? "On - meeting audio is written to local WAV files"
                    : "Off"
            ) {
                if audioDumpEnabled {
                    Button("Disable") {
                        UserDefaults.standard.set(false, forKey: "debugAudioDump")
                        refresh()
                    }
                    .controlSize(.small)
                }
            }

            statusRow(
                title: "Diagnostics log",
                enabled: diagnosticsEnabled,
                detail: diagnosticsEnabled
                    ? "On - pipeline diagnostics are written locally"
                    : "Off"
            ) {
                Button("Reveal") {
                    revealDebugDirectory()
                }
                .controlSize(.small)
            }

            if debugFileCount > 0 {
                HStack {
                    Text("\(debugFileCount) debug file\(debugFileCount == 1 ? "" : "s") in Application Support")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete") {
                        deleteDebugArtifacts()
                    }
                    .controlSize(.small)
                }
            }

            if let cleanupMessage {
                Text(cleanupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { refresh() }
    }

    private func statusRow(
        title: String,
        enabled: Bool,
        detail: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack {
            Image(systemName: enabled ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(enabled ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    private func refresh() {
        audioDumpEnabled = UserDefaults.standard.bool(forKey: "debugAudioDump")
        diagnosticsEnabled = UserDefaults.standard.bool(forKey: "debugDiag")
        debugFileCount = (try? DebugArtifacts.artifactCount()) ?? 0
    }

    private func revealDebugDirectory() {
        try? FileManager.default.createDirectory(
            at: DebugArtifacts.directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([DebugArtifacts.directory])
        refresh()
    }

    private func deleteDebugArtifacts() {
        do {
            let deleted = try DebugArtifacts.deleteArtifacts()
            cleanupMessage = deleted == 0
                ? "No debug files to delete"
                : "Deleted \(deleted) debug file\(deleted == 1 ? "" : "s")"
        } catch {
            cleanupMessage = "Couldn't delete debug files: \(error.localizedDescription)"
        }
        refresh()
    }
}

struct MonitoredAppsList: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        ForEach(MeetingApps.known, id: \.bundleID) { app in
            Toggle(app.name, isOn: Binding(
                get: { settings.monitoredBundleIDs.contains(app.bundleID) },
                set: { enabled in
                    if enabled {
                        if !settings.monitoredBundleIDs.contains(app.bundleID) {
                            settings.monitoredBundleIDs.append(app.bundleID)
                        }
                    } else {
                        settings.monitoredBundleIDs.removeAll { $0 == app.bundleID }
                    }
                }
            ))
        }
    }
}

struct TranscriptionSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var supportedLocales: [Locale] = []

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $settings.asrEngine) {
                    ForEach(ASREngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("On-device keeps all audio on your Mac. OpenAI requires an API key (Account tab) and sends audio to OpenAI. Speaker identification always runs on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                if supportedLocales.isEmpty {
                    LabeledContent("Language", value: settings.transcriptionLocaleID)
                } else {
                    Picker("Language", selection: $settings.transcriptionLocaleID) {
                        // Keep the current value selectable even if it isn't
                        // an exact member of the supported list.
                        if !supportedLocales.contains(where: { $0.identifier == settings.transcriptionLocaleID }) {
                            Text(displayName(settings.transcriptionLocaleID))
                                .tag(settings.transcriptionLocaleID)
                        }
                        ForEach(supportedLocales, id: \.identifier) { locale in
                            Text(displayName(locale.identifier)).tag(locale.identifier)
                        }
                    }
                }
            }

            Section("OpenAI Model") {
                TextField("Realtime transcription model", text: $settings.openAITranscriptionModel)
                    .disabled(settings.asrEngine != .openAI)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
        .task {
            supportedLocales = await SpeechTranscriber.supportedLocales
                .sorted { $0.identifier < $1.identifier }
        }
    }
}

struct NotesSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Summarization") {
                Picker("Notes engine", selection: $settings.notesEngine) {
                    ForEach(NotesEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("Update notes every", selection: $settings.notesCadenceSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                TextField("OpenAI notes model", text: $settings.openAINotesModel)
            }

            Section {
                TextEditor(text: $settings.notesPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        settings.resetNotesPrompt()
                    }
                    .disabled(settings.notesPrompt == DefaultPrompts.notes)
                }
            } header: {
                Text("Notes Prompt")
            } footer: {
                Text("This prompt instructs AI notes engines how to summarize your meetings. Cloud notes send current notes and new transcript text to OpenAI with response storage disabled. Automatic mode uses Apple on-device notes when available, then OpenAI when an API key is saved, then local extractive notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}

struct AccountSettingsView: View {
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = KeychainStore.hasAPIKey
    @State private var testResult: String?
    @State private var keyStatus: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                if hasStoredKey {
                    HStack {
                        Label("Key saved in Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove") {
                            do {
                                try KeychainStore.deleteAPIKey()
                                hasStoredKey = false
                                testResult = nil
                                keyStatus = nil
                            } catch {
                                keyStatus = error.localizedDescription
                            }
                        }
                    }
                } else {
                    HStack {
                        SecureField("sk-…", text: $apiKeyDraft)
                            .onSubmit { saveKey() }
                        Button("Save") { saveKey() }
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text("Stored in your device-local Keychain. Required only for cloud transcription or cloud notes — speaker identification always runs on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keyStatus {
                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if hasStoredKey {
                Section("Connection") {
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection") {
                            testConnection()
                        }
                        .disabled(testing)
                        if let testResult {
                            Text(testResult)
                                .font(.callout)
                                .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }

    private func saveKey() {
        do {
            try KeychainStore.saveAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            hasStoredKey = true
            testResult = nil
            keyStatus = nil
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func testConnection() {
        let key: String
        do {
            guard let storedKey = try KeychainStore.readAPIKey() else {
                testResult = "No API key saved"
                return
            }
            key = storedKey
        } catch {
            testResult = error.localizedDescription
            return
        }
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                testResult = status == 200
                    ? "✓ Connected"
                    : (status == 401 ? "Invalid API key" : "HTTP \(status)")
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
