# Project Goal And Backlog

Version: 0.2.0
Last updated: 2026-06-12

## Proposed Goal

Build a reliable, privacy-first native macOS meeting transcriber that can be trusted for
real meetings: capture microphone and system audio, produce speaker-attributed live
transcripts and useful key notes, preserve transcript-only history/export, and make cloud
features optional, explicit, and recoverable.

The first project milestone is **v1 reliability in the primary development environment** before wider packaging or
distribution.

## V1 Boundary

V1 readiness means the app can be trusted for real meetings in the primary development environment. It does
not mean public distribution, notarized release packaging, persistent speaker enrollment,
or a broad export/product-polish pass.

Included in v1:

- Local-first meeting detection, capture, transcription, diarization, notes, stop,
  persistence, and Markdown export.
- Explicit and recoverable OpenAI behavior for optional cloud ASR and cloud notes.
- Transcript-only persistence by default; no meeting audio persistence except explicit
  debug audio dumps.
- A real Zoom or Google Meet validation run in the primary development environment.

Not included in v1:

- Public distribution, Sparkle updates, App Store feasibility, or production notarization.
- Persistent speaker enrollment across meetings.
- Additional export formats beyond what is needed to verify transcript and notes output.
- Product-polish features such as search, filters, action-item UI, or streaming notes.

## Project Harness

- Intent: turn the Fable-generated prototype into a dependable local-first macOS app.
- Good means: real meetings can be detected, started, transcribed, diarized, summarized,
  stopped, persisted, and exported without data loss or unclear cloud/privacy behavior.
- Evidence: passing build/test/analyze checks, live app launch, a synthetic audio smoke
  path where available, at least one real Zoom or Google Meet end-to-end run, verified notes
  engine behavior, verified cloud fallback behavior if OpenAI ASR remains supported, and
  exported transcript review.
- Risks: native audio/TCC paths appear to work in isolation but fail in real meetings;
  OpenAI API drift breaks cloud ASR; persistence silently loses transcript data; diarizer
  state leaks across logical sessions; unbounded audio buffering accumulates raw meeting
  audio when consumers stall; debug audio or cloud paths weaken the privacy promise;
  distribution settings are mistaken for production-ready.
- Work mode: plan then build for v1 readiness, with research-first checks for OpenAI and
  entitlements before implementation.
- Harness: keep this document as the backlog, use `project.yml` as the build source of
  truth, and require concrete verification notes for each completed gate and backlog item.
- First path: establish a fresh baseline, fix known correctness/data-loss/privacy risks,
  then run a real-meeting validation pass before adding polish.

## V1 Readiness Checkpoints

### Baseline

- Confirm repository state and current commit.
- Regenerate the Xcode project from `project.yml`.
- Run build/test/analyze checks.
- Launch the app and record what live TCC/audio behavior was or was not verified.

### Meeting Trust Fixes

- Cloud ASR is either compatible with the current OpenAI Realtime API or disabled with a
  clear UI/settings path.
- Diarizer state resets across new logical meetings while remaining stable for intentional
  mid-session cloud-to-local fallback.
- Critical SwiftData persistence failures are surfaced or retained as retryable state.
- Audio buffering is bounded so a stalled consumer cannot accumulate unbounded raw meeting
  audio.
- OpenAI notes make transcript-text sharing and provider storage behavior explicit.

### Local Real-Meeting Proof

- Run Zoom and/or Google Meet: detection banner, start, mic/system capture, live transcript,
  remote speaker attribution, notes update, stop, persistence, and export.
- Record exact environment conditions: permissions, Apple Intelligence state, output device,
  app version/commit, ASR engine, notes engine, and whether debug audio/diagnostics were on.

### V1 Closeout

- Update privacy documentation to match actual behavior.
- Record any accepted limitations that remain for v1.
- Defer distribution, signing/notarization, and broader product polish unless a v1 gate
  exposes them as blockers.

## V1 Readiness Backlog

### P0 - Correctness And Trust

1. **Fix OpenAI Realtime ASR compatibility.**
   - Confirm current Realtime transcription model/config from official OpenAI docs.
   - Decide whether cloud ASR remains supported for v1; if not, disable it with clear
     settings/UI copy and keep local ASR as the supported path.
   - If supported, replace the default `gpt-4o-transcribe-diarize` model with a supported
     Realtime transcription model and update the session config, turn handling, transcript
     events, and timing strategy together.
   - Current docs on 2026-06-12 point to `gpt-realtime-whisper` for live streaming
     transcription; verify whether the app should use manual audio commits instead of
     server VAD before coding.
   - Add a focused integration check for session config, audio append/commit, transcript
     delta, final transcript, reconnect, fatal config errors, and fallback.
   - Current local coverage: session payload, manual-commit-compatible config, delta
     accumulation, final transcript timing, transcription-failed events, fatal model/auth
     errors, retry exhaustion, and successful transient reconnect with committed audio
     timing are unit-tested. Live service reconnect and app-level cloud-to-local fallback
     remain unverified.

2. **Separate diarizer lifecycle between logical sessions.**
   - Reset or recreate the FluidAudio diarizer for a new meeting.
   - Preserve speaker state only for intentional mid-session cloud-to-local fallback.
   - Add tests or a lightweight harness proving two consecutive sessions do not leak
     timeline or speaker state.
   - Current local coverage: new-session reset clears transcript, volatile text, speakers,
     and diarizer fed-time state; mid-session timeline reset preserves finalized transcript
     and renamed speakers while dropping stale attribution windows and failed-engine volatile
     text.

3. **Stop silently swallowing persistence failures.**
   - Replace critical `try? context.save()` calls with surfaced errors or durable retry state.
   - Make final save failure visible to the user.
   - Add tests around empty-session discard, final sync, and save-failure behavior.

4. **Verify real meeting end-to-end behavior.**
   - Run Zoom and/or Google Meet: detection banner, start, mic/system capture, live transcript,
     remote speaker attribution, notes update, stop, persistence, export.
   - Record exact environment conditions: permissions, Apple Intelligence state, output device,
     app version/commit, and engine choices.
   - Current local proof: detector debounce, end-grace callback, browser-to-dedicated-app
     switching, and post-ASR transcript/persistence/export fixture behavior are unit-tested;
     a real Zoom/Meet run is still required.
   - Current proof support: `scripts/gate2-real-meeting-proof.sh` records preflight state,
     launches the debug app with `debugAudioDump=NO`, and summarizes the newest SwiftData
     session metadata without printing transcript or title text. Its summary fails the run
     unless a new ended session has transcript rows, microphone rows, system rows, multiple
     transcript speakers, notes, and an ASR engine.
   - Export proof support: after saving Markdown through the app, the helper can verify the
     exported file's duration, source app, transcript section, transcript row count, multiple
     speaker labels, and notes section without printing or copying transcript/notes text.

5. **Make cloud notes privacy explicit and controlled.**
   - Set `store: false` for OpenAI Responses requests unless a product decision says otherwise.
   - Clarify in UI/settings that cloud notes send transcript text to OpenAI, including
     automatic fallback behavior.
   - Verify OpenAI notes with the current Responses API response shape.
   - Current local fallback: Automatic notes use Apple on-device notes when available,
     OpenAI only when a key is saved, then local extractive notes that use transcript text
     already generated inside the app and make no model or network calls.

6. **Bound audio stream buffering and backpressure.**
   - Replace unbounded audio streams where a stalled consumer can accumulate raw audio.
   - Define behavior for lag: drop, pause, degrade, or stop with an error.
   - Add diagnostics for slow ASR, diarizer, and cloud consumers.
   - Current approach: capture streams, ASR fan-out streams, diarization fan-out streams,
     and local SpeechAnalyzer input all use bounded `.bufferingNewest(120)` queues.
     When a consumer stalls, older queued raw-audio chunks are dropped so the app favors
     returning to live behavior over accumulating meeting audio. Drops are counted in
     diagnostics on the first drop and every 100 drops per label.

### P1 - Runtime Hardening

7. **Improve capture degradation states.**
   - Make system-only capture, mic failure, system tap failure, and output-device rebuilds
     obvious in the UI and logs.
   - Validate sleep/wake and output-device switch behavior.

8. **Build an audio fixture integration test path.**
   - Feed canned WAV fixtures through the transcription/diarization/attribution pipeline
     without requiring live TCC grants where possible.
   - Keep live meeting validation as the final proof.
   - Current local coverage: `TranscriptPipelineFixtureTests` drives scripted engine events
     and diarizer intervals through volatile-text clearing, echo suppression, speaker
     attribution, speaker rename, SwiftData finish, and Markdown export without capture
     devices or TCC.
   - Current WAV coverage: `AudioFixture` loads canned WAV files into deterministic
     `AudioChunk` streams; `AudioFixtureTests` verifies chunking, stream order, and
     fixture-derived microphone/system turns through attribution, SwiftData finish, and
     Markdown export without capture devices or TCC.
   - Current model-fixture support: `scripts/run-audio-fixture-model-proof.sh` generates a
     temporary speech WAV and runs opt-in `ModelFixtureProofTests`. The default script path
     verifies FluidAudio LS-EEND consumes fixture chunks through `DiarizationService` with
     model processing attempts and no processing errors. With `--include-local-asr`, the
     local SpeechTranscriber probe also verifies generated-speech WAV chunks through the
     app's `LocalSpeechEngine` stream path.
   - Current local ASR fixture status: `LocalSpeechEngine` now feeds SpeechAnalyzer
     `AnalyzerInput` values with monotonic frame-based `bufferStartTime` values and bounds
     analyzer finalization so `stop()` can finish the engine event stream even when
     SpeechAnalyzer does not drain normally.
   - Remaining: generated fixtures do not prove FluidAudio diarization accuracy,
     multi-speaker separation, live microphone/system capture, live local ASR quality, or
     real meeting behavior.

9. **Strengthen OpenAI fallback behavior.**
   - Verify reconnect behavior, fatal config errors, and mid-session cloud-to-local fallback.
   - Ensure fallback does not duplicate, drop, or mis-time transcript segments.
   - Current local coverage: fatal model/auth Realtime events are classified so the app can
     enter the existing cloud-to-local fallback path; the transcript pipeline now clears
     failed-engine volatile text, preserves finalized transcript and renamed speaker state,
     drops old attribution windows across an engine timeline restart, and reuses a repeated
     diarizer cluster after fallback. Fake transport tests now prove receive failures and
     reconnect-session-update failures retry, replay `session.update`, preserve committed
     audio timing after a transient reconnect, and finish the engine event stream with an
     error when retry budget is exhausted. Live API-backed reconnect and mid-session
     cloud-to-local fallback still need proof.

10. **Add long-meeting soak coverage.**
    - Test 2+ hour memory, SwiftData write behavior, ASR session longevity, and UI responsiveness.
    - Current local coverage: `SessionRecorderTests.longSessionSnapshotPersistsAndExportsTwoHourTimeline`
      persists a 750-segment, three-speaker, microphone/system-source fixture across a
      2:05:00 session and verifies SwiftData segment/source counts, speaker records, final
      duration/end state, and ordered Markdown export across hour-scale timestamps.
    - Remaining: this is not a live memory profile, ASR longevity test, FluidAudio/WAV run,
      or UI responsiveness soak.

### P2 - Security, Privacy, And Distribution

11. **Create a release signing/notarization plan.**
   - Audit entitlements, hardened runtime, sandbox feasibility, and TCC prompts.
   - Keep development settings separate from distribution settings.
   - Verify the built app artifact when signing work begins; do not rely only on
     `project.yml`.
   - Current audit: `docs/RELEASE_SIGNING_NOTARIZATION.md` verifies that current local
     Release artifacts are not notarized distribution artifacts and need a separate
     Developer ID/notarization track before publishing user-installable binaries.

12. **Add dependency locking and supply-chain checks.**
   - Decide how to preserve `Package.resolved` with XcodeGen.
   - Add a lightweight dependency/update review process for FluidAudio.
   - Current approach: root `Package.resolved` is canonical, `xcodegen generate` restores
     it into the generated project, and `scripts/sync-package-lock.sh --verify` checks for
     drift.

13. **Review Keychain handling.**
    - Confirm API key accessibility class and app access behavior are appropriate.
    - Consider update-in-place instead of delete/add for key save.
    - Current approach: new API key saves use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`;
      existing keys are updated with `SecItemUpdate`; Settings surfaces save/remove/read
      errors instead of silently treating them as missing keys.

14. **Guard debug artifacts.**
    - Make debug audio dump status visible when enabled.
    - Provide a cleanup path for debug WAVs and diagnostic logs.
    - Current approach: Settings -> General -> Diagnostics shows `debugAudioDump` and
      `debugDiag` state, reveals the debug folder, counts known debug artifacts, and can
      delete `*.wav` files plus `diag.log` without touching unrelated files.

15. **Document the privacy model.**
    - State exactly what stays local, what can go to OpenAI, what is persisted, and where
      debug artifacts can be written.

### P3 - Product Polish

16. **Transcript search and per-speaker filters.**
17. **Jump-to-live behavior when the user scrolls during active transcription.**
18. **Additional export formats: plain text, JSON, notes-only, transcript-only, clipboard.**
19. **Action-item extraction into a checklist UI.**
20. **Opt-in persistent speaker enrollment.**
21. **Streaming notes updates instead of wholesale replacement.**
22. **Locale-aware diarizer options and max-speakers hint.**
23. **Notification re-enable and actionable notification validation.**
24. **Wake/resume capture rebuild UX.**

## Definition Of Done For Backlog Items

Each completed item should include:

- Code/docs changed, if any.
- Verification command or live-app check.
- What was not verified and why.
- Any user-facing privacy, permission, or data-retention impact.
- Follow-up item if the fix exposes a larger design decision.

Each completed gate should include a short dated note with the commands, live checks,
environment conditions, and accepted limitations that support moving to the next gate.
