import Testing
@testable import Transcriber

struct LocalSpeechEngineTests {
    @Test func finalizationTimeoutReturnsWhenOperationStalls() async {
        let clock = ContinuousClock()
        let start = clock.now

        let outcome = await LocalASRFinalization.run(timeout: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(60))
        }

        #expect(outcome == .timedOut)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func finalizationTimeoutReportsCompletion() async {
        let outcome = await LocalASRFinalization.run(timeout: .seconds(1)) {}

        #expect(outcome == .completed)
    }
}
