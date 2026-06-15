import Testing
@testable import Transcriber

struct LocalNotesEngineTests {
    @Test func extractiveNotesBuildUsefulMarkdownBullets() async throws {
        let engine = LocalExtractiveNotesEngine()

        let notes = try await engine.updateNotes(
            existing: "",
            newTranscript: """
            Speaker 1: We need Alice to send the budget review by Friday.
            Speaker 2: The launch risk is onboarding, and support should prepare the checklist.
            Speaker 1: Okay.
            """,
            instructions: "Summarize action items."
        )

        #expect(notes.contains("- We need Alice to send the budget review by Friday"))
        #expect(notes.contains("- The launch risk is onboarding"))
        #expect(!notes.contains("Okay"))
    }

    @Test func extractiveNotesMergeWithoutDuplicatingExistingBullets() async throws {
        let engine = LocalExtractiveNotesEngine()

        let notes = try await engine.updateNotes(
            existing: "- We need Alice to send the budget review by Friday",
            newTranscript: """
            You: We need Alice to send the budget review by Friday.
            Speaker 2: The team agreed to ship the fixture proof after review.
            """,
            instructions: ""
        )

        #expect(notes.components(separatedBy: "budget review").count == 2)
        #expect(notes.contains("- The team agreed to ship the fixture proof after review"))
    }
}

@MainActor
struct NotesCoordinatorTests {
    @Test func finalTickUsesLocalExtractiveNotesEngine() async {
        let coordinator = NotesCoordinator()
        var appliedNotes = ""

        coordinator.engineProvider = { LocalExtractiveNotesEngine() }
        coordinator.currentNotes = { "" }
        coordinator.applyNotes = { appliedNotes = $0 }
        coordinator.transcriptDelta = { cursor in
            #expect(cursor == 0)
            return (
                "Speaker 1: We need to review capture reliability before the next meeting.",
                1
            )
        }

        await coordinator.finish()

        #expect(appliedNotes.contains("review capture reliability"))
        #expect(coordinator.lastIssue == nil)
    }
}
