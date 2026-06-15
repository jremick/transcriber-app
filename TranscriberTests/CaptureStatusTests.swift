import Testing
@testable import Transcriber

struct CaptureStatusTests {
    @Test func liveStatusIsNilWhenMicrophoneIsAvailable() {
        #expect(CaptureStatus.live(micUnavailable: false) == nil)
    }

    @Test func liveStatusExplainsSystemOnlyMode() {
        let status = CaptureStatus.live(micUnavailable: true)

        #expect(status?.title == "System audio only")
        #expect(status?.systemImage == "mic.slash.fill")
        #expect(status?.detail.contains("your voice may be missing") == true)
    }

    @Test func subtitleCallsOutSystemOnlyRecording() {
        #expect(CaptureStatus.subtitle(
            recordingState: .recording,
            sourceApp: "Chrome",
            micUnavailable: true
        ) == "Capturing Chrome - system audio only")
        #expect(CaptureStatus.subtitle(
            recordingState: .paused,
            sourceApp: "Chrome",
            micUnavailable: true
        ) == "Paused - system audio only")
    }
}
