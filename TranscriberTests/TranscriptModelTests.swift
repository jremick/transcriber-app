import Testing
@testable import Transcriber

struct TranscriptModelTests {
    @Test func clockFormatting() {
        #expect(FormatStyle.clock(0) == "00:00")
        #expect(FormatStyle.clock(65) == "01:05")
        #expect(FormatStyle.clock(3725) == "1:02:05")
    }

    @Test func speakerIDs() {
        #expect(SpeakerID.you.isYou)
        #expect(!SpeakerID.remote(1).isYou)
        #expect(SpeakerID.remote(2).key == "spk-2")
    }
}
