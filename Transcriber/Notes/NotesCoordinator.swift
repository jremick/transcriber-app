import Foundation
import Observation

/// Drives periodic notes updates during a session. Never blocks the
/// transcription path; skips a tick when an update is already in flight.
@MainActor
@Observable
final class NotesCoordinator {
    /// Most characters of new transcript per update; keeps the on-device
    /// model comfortably inside its context window.
    private let maxDeltaCharacters = 7000
    /// Skip a tick when fewer than this many new characters arrived.
    private let minDeltaCharacters = 40

    private(set) var isUpdating = false
    private(set) var lastIssue: String?

    private var tickTask: Task<Void, Never>?
    private var cursor = 0

    var engineProvider: () -> NotesEngine? = { nil }
    var promptProvider: () -> String = { DefaultPrompts.notes }
    var cadenceProvider: () -> Int = { 30 }
    /// Returns (formatted new transcript lines, new cursor) since `cursor`.
    var transcriptDelta: (_ cursor: Int) -> (text: String, cursor: Int) = { _ in ("", 0) }
    var currentNotes: () -> String = { "" }
    var applyNotes: (String) -> Void = { _ in }

    func start() {
        stop()
        cursor = 0
        lastIssue = nil
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let cadence = self?.cadenceProvider() ?? 30
                try? await Task.sleep(for: .seconds(max(10, cadence)))
                await self?.tick(final: false)
            }
        }
    }

    /// One last update covering the tail of the meeting.
    func finish() async {
        tickTask?.cancel()
        tickTask = nil
        await tick(final: true)
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        isUpdating = false
    }

    /// Re-run on demand (manual refresh button).
    func refreshNow() {
        Task { await tick(final: false) }
    }

    private func tick(final: Bool) async {
        guard !isUpdating else { return }
        guard let engine = engineProvider() else {
            lastIssue = "No notes engine available. Check Settings → Notes."
            return
        }
        var (delta, newCursor) = transcriptDelta(cursor)
        guard !delta.isEmpty, final || delta.count >= minDeltaCharacters else { return }
        if delta.count > maxDeltaCharacters {
            delta = String(delta.suffix(maxDeltaCharacters))
        }

        isUpdating = true
        defer { isUpdating = false }
        do {
            let updated = try await engine.updateNotes(
                existing: currentNotes(),
                newTranscript: delta,
                instructions: promptProvider()
            )
            cursor = newCursor
            lastIssue = nil
            applyNotes(updated)
        } catch {
            lastIssue = error.localizedDescription
            DebugDiag.log("notes update failed: \(error)")
        }
    }
}
