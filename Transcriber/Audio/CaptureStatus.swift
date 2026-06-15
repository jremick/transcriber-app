import Foundation

/// User-facing summary of degraded live capture modes.
struct CaptureStatus: Equatable, Sendable {
    let title: String
    let detail: String
    let systemImage: String

    static func live(micUnavailable: Bool) -> CaptureStatus? {
        guard micUnavailable else { return nil }
        return CaptureStatus(
            title: "System audio only",
            detail: "Microphone capture is unavailable, so your voice may be missing from this session.",
            systemImage: "mic.slash.fill"
        )
    }

    static func subtitle(
        recordingState: RecordingState,
        sourceApp: String?,
        micUnavailable: Bool
    ) -> String {
        switch recordingState {
        case .idle:
            return ""
        case .preparing:
            return "Preparing..."
        case .recording:
            let base = sourceApp.map { "Capturing \($0)" } ?? "Recording"
            return micUnavailable ? "\(base) - system audio only" : base
        case .paused:
            return micUnavailable ? "Paused - system audio only" : "Paused"
        }
    }
}
