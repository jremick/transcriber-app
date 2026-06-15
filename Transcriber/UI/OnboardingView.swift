import AVFoundation
import SwiftUI
import UserNotifications

/// First-run sheet: explains the app, walks through permissions, and
/// pre-downloads the on-device models so the first meeting starts instantly.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notificationsGranted: Bool?
    @State private var modelProgress: Double?
    @State private var modelsReady = false
    @State private var modelError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text("Welcome to Transcriber")
                    .font(.title.weight(.semibold))
                Text("Live meeting transcripts with speaker names and AI key notes — processed on your Mac by default.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            VStack(spacing: 10) {
                stepRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Captures your side of the conversation.",
                    status: micGranted ? .done : .pending
                ) {
                    Button(micGranted ? "Granted" : "Grant Access") {
                        Task {
                            _ = await MicCaptureService.requestPermission()
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                    }
                    .disabled(micGranted)
                }

                stepRow(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    detail: "Captures other participants. macOS will ask the first time a session starts.",
                    status: .info
                ) {
                    EmptyView()
                }

                stepRow(
                    icon: "bell.badge.fill",
                    title: "Notifications",
                    detail: "Get a prompt when a meeting is detected.",
                    status: notificationsGranted == true ? .done : .pending
                ) {
                    Button(notificationsGranted == true ? "Enabled" : "Enable") {
                        Task {
                            notificationsGranted = await appState.notifications.requestAuthorization()
                        }
                    }
                    .disabled(notificationsGranted == true)
                }

                stepRow(
                    icon: "arrow.down.circle.fill",
                    title: "On-device Models",
                    detail: modelError ?? "Speech and speaker-identification models (one-time download).",
                    status: modelsReady ? .done : .pending
                ) {
                    if let progress = modelProgress, !modelsReady {
                        ProgressView(value: progress)
                            .frame(width: 90)
                    } else {
                        Button(modelsReady ? "Ready" : "Download") {
                            downloadModels()
                        }
                        .disabled(modelsReady || modelProgress != nil)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            Button {
                settings.hasCompletedOnboarding = true
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 540)
        .task {
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            notificationsGranted = status == .authorized || status == .provisional
        }
    }

    private var micGranted: Bool { micStatus == .authorized }

    private enum StepStatus { case done, pending, info }

    @ViewBuilder
    private func stepRow(
        icon: String, title: String, detail: String, status: StepStatus,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(status == .done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func downloadModels() {
        modelProgress = 0
        modelError = nil
        Task {
            do {
                try await appState.predownloadModels { fraction in
                    modelProgress = fraction
                }
                modelsReady = true
            } catch {
                modelError = error.localizedDescription
            }
            modelProgress = nil
        }
    }
}
