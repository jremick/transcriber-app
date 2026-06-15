import Testing
@testable import Transcriber

struct DiarizationServiceTests {
    @Test func resetForNewSessionClearsTimelineState() async {
        let service = DiarizationService()

        await service.debugAdvanceFedSecondsForTests(12.5)
        let before = await service.debugStateForTests()
        #expect(before.totalFedSeconds == 12.5)

        await service.resetForNewSession()
        let after = await service.debugStateForTests()
        #expect(after.totalFedSeconds == 0)
        #expect(!after.hasDiarizer)
    }
}
