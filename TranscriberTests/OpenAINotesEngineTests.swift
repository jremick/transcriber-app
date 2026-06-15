import Foundation
import Testing
@testable import Transcriber

struct OpenAINotesEngineTests {
    @Test func requestPayloadDisablesResponseStorage() {
        let payload = OpenAINotesEngine.requestPayload(
            model: "gpt-5-mini",
            input: "New transcript portion:\nAlex: Ship it.",
            instructions: "Summarize decisions."
        )

        #expect(payload["model"] as? String == "gpt-5-mini")
        #expect(payload["instructions"] as? String == "Summarize decisions.")
        #expect(payload["input"] as? String == "New transcript portion:\nAlex: Ship it.")
        #expect(payload["store"] as? Bool == false)
    }
}
