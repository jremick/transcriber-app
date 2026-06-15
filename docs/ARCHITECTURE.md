# Architecture

Swift 6 (strict concurrency), SwiftUI, macOS 26+. UI and `AppState` live on `@MainActor`;
services are actors or isolated classes. This document describes what's implemented and why.

## 1. Audio capture (`Transcriber/Audio/`)

### Two-stream model

The defining design decision: **microphone and system audio are captured, transcribed,
and attributed separately.**

- `MicCaptureService` — `AVAudioEngine` with voice processing (AEC) enabled so speaker
  output doesn't bleed into the mic channel. AEC initialization is fragile
  (`-10875`, `'!dev'`, `canPerformIO=false` — especially while another app records), so the
  ladder is: VP engine → plain engine → 0.7 s-delayed plain retry → Core Audio HAL input
  IOProc fallback. The HAL path reads the native input stream format, downmixes mic-array
  input to mono Float32, and yields normal microphone chunks. If all mic paths fail, the
  app **degrades to system-only capture** (session continues, toolbar shows a mic-off chip)
  rather than fail.
- `SystemAudioTapService` — Core Audio **process tap** (`AudioHardwareCreateProcessTap`,
  mono mixdown of every process except our own) → private aggregate device (pinned to the
  current default output device, drift-compensated) → IOProc. A listener on
  `kAudioHardwarePropertyDefaultOutputDevice` tears down and rebuilds the tap when the
  output device changes (AirPods connect mid-meeting).
- `CaptureController` — owns both services per session. Fans the system stream out to two
  consumers (ASR + diarizer), computes throttled level meters, drops audio while paused,
  and optionally writes debug WAVs.

### Timeline model (important)

The system tap **emits nothing during silence**, so "seconds of audio fed to the ASR" drifts
arbitrarily from wall clock, and differently per stream.

- `SessionClock` — pause-aware session clock (thread-safe, lock-based).
- `TimelineMapper` (one per stream) — records each forwarded chunk against the session
  clock and keeps piecewise anchors (one per gap). Converts fed-audio timestamps →
  session time.

Everything downstream agrees on this convention:

| Stage | Timebase |
|---|---|
| ASR engine output (`TranscriptSegment.start/end` at emit) | fed-audio time |
| Diarizer intervals | fed-audio time (same stream ⇒ identical timeline) |
| `SpeakerAttributor` overlap matching | fed-audio time |
| `TranscriptAssembler`, UI, persistence, export | session time (converted in `AppState.apply`) |

Audio-format conversions all go through `AudioResampler` (`AVAudioConverter` wrapper):
analyzer-native format for SpeechTranscriber, 16 kHz mono f32 for FluidAudio, 24 kHz mono
s16 for OpenAI.

### Swift 6 gotcha (recurring)

Closures formed inside `@MainActor` context but invoked on audio/dispatch queues
(`installTap`, `AudioDeviceCreateIOProcIDWithBlock`, KVO sinks) inherit MainActor isolation
and **trap at runtime** (`dispatch_assert_queue_fail`). Every such callback is explicitly
`@Sendable` and touches only Sendable state; buffers are deep-copied before crossing.

## 2. Transcription engines (`Transcriber/Transcription/`)

`TranscriptionEngine` protocol: `prepare(locale:progress:)`,
`start(micStream:systemStream:) -> AsyncThrowingStream<EngineEvent>`, `stop()`.
Events are `.volatile(source, text)` (replaces the live tail) and `.final(TranscriptSegment)`.

- `LocalSpeechEngine` — two `SpeechAnalyzer` + `SpeechTranscriber` pipelines (one per
  stream), volatile results on, `audioTimeRange` attributes for timestamps.
  `AssetInventory` handles model download (progress is **polled**; KVO publishers crash
  under strict concurrency — see gotcha above). Locale resolution tolerates extension-laden
  system locales (e.g. `en_US@rg=auzzzz`): exact bcp47 → language+override-region →
  language+base-region → language-only.
- `OpenAIRealtimeEngine` — one WebSocket per stream
  (`wss://api.openai.com/v1/realtime?intent=transcription`), 24 kHz PCM16 base64 frames,
  manual audio commits for `gpt-realtime-whisper`. Text only — its speaker labels (if any)
  are ignored. Segment time ranges come from committed audio windows mapped onto the
  bytes-sent timeline; VAD events are still handled for compatibility with models that emit
  them. Reconnects with bounded retries; fatal config errors (`model`, `auth`) fail fast so
  the fallback can engage.

### Mid-session cloud→local fallback

If the cloud engine's event stream throws while recording, `AppState.handleEngineFailure`:

1. force-resolves pending attributions, resets the attributor's *timeline* (intervals/watermark)
2. stops capture + engines, starts `LocalSpeechEngine` against **fresh capture streams**
3. keeps: the session clock, transcript, speakers, notes, and — critically — the **same
   diarizer instance**, so cluster indices (speaker identities) remain stable

`DiarizationService` makes this work by rebasing each `run()` to report 0-based times
(`totalFedSeconds` bookkeeping), matching the restarted ASR/mapper timelines.

## 3. Diarization & attribution

- `DiarizationService` (actor) — FluidAudio **LS-EEND** (`dihard3`, 100 ms steps),
  streaming `process(samples:)` over the dedicated system-stream copy; emits
  `SpeakerInterval { clusterIndex, start, end }`. Fully on-device; the model caches under
  `~/Library/Application Support/FluidAudio/Models/`.
- `SpeakerAttributor` (pure struct, unit-tested) — merges ASR segments with diarizer
  intervals by **max time-overlap**. Segments whose end the diarizer hasn't reached yet
  (watermark + 0.25 s slack) queue as pending; resolved when the diarizer catches up or
  after 5 s staleness (then: nearest interval within 3 s, else cluster 0). Adjacent
  same-cluster intervals merge.
- **Echo suppression** — AEC is never perfect; when speakers are used, the mic re-captures
  remote audio and both streams transcribe the same words. `TextSimilarity`
  (max of word-set Jaccard, containment, and normalized character-level Levenshtein — the
  char metric catches short ASR-noisy near-duplicates) drops mic segments ≥ 0.7 similar to
  a system segment within ±5 s, in both arrival orders.

Speaker display: `SpeakerID.you` ("You", color 0) for the mic; `spk-N` mapped to
"Speaker 1…N" in order of first appearance. Renames are per-session and persisted.

## 4. Meeting detection (`Transcriber/Detection/`)

- `AudioProcessMonitor` (actor) — polls Core Audio process objects
  (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput` +
  bundle-ID property) every 2 s: a cheap, permissionless answer to "which apps are using
  the mic right now". Polling beats per-process listeners on simplicity; process objects
  churn constantly.
- `MeetingDetector` — state machine `idle → candidate (2 s debounce) → active →
  ending (20 s grace) → idle` over the intersection of mic-active apps and the monitored
  list. Known browser helper bundle IDs are canonicalized back to the top-level browser
  app before matching. Dedicated meeting apps outrank browsers; browser hits are
  `isTentative` ("Possible meeting") because any website could be using the mic.
- Actions on detection: per settings, post an actionable notification **and** an in-app
  banner (`AppState.pendingDetection`, also surfaced in the menu bar) — the banner exists
  because notification permission can be denied — or auto-start (non-tentative apps only).
  Sessions started by detection auto-stop after the end-grace if the setting is on.

## 5. Notes (`Transcriber/Notes/`)

`NotesEngine` protocol: `updateNotes(existing:newTranscript:instructions:) -> String`.

- `FoundationModelsNotesEngine` — on-device. **Rolling summarization**: state lives in the
  notes text itself; each update sends instructions + current notes + new transcript lines
  in a *fresh* `LanguageModelSession`, keeping well inside the ~4k-token context window.
  Availability gates (Apple Intelligence off / model downloading / ineligible device)
  surface as actionable footer messages.
- `OpenAINotesEngine` — same contract via the Responses API, with response storage disabled
  on requests.
- `LocalExtractiveNotesEngine` — deterministic local fallback. It extracts useful
  speaker-labeled transcript lines into compact Markdown bullets. It does not call a model
  or send text to a network service.
- `NotesCoordinator` — ticks every `notesCadenceSeconds` (≥10 s), skips when an update is
  in flight or fewer than ~40 new chars arrived, caps the delta at 7k chars, runs one final
  tail update on stop. Engine choice: automatic (Foundation Models → OpenAI when a key is
  saved → local extractive), forced on-device, forced local extractive, or forced cloud.
  Never blocks the transcript path.

The default prompt lives in `Settings/DefaultPrompts.swift`; Settings → Notes exposes it
in an editor with reset.

## 6. Persistence & export (`Transcriber/Persistence/`)

- SwiftData models: `MeetingSession` ←(cascade)→ `TranscriptSegmentRecord`,
  `SpeakerRecord`. Transcript-only; **no audio is ever persisted**.
- `SessionRecorder` — a 5 s **upsert sync** of live state rather than per-event writes,
  because diarization reassigns speakers and echo suppression deletes segments *after*
  they're first displayed. Also: empty sessions are discarded on stop, and a launch-time
  repair pass closes out sessions left open by a crash.
- `TranscriptExporter` — Markdown (title/date/duration/app, Key Notes, speaker-attributed
  timestamped transcript) via save panel; also in the sidebar context menu.
- OpenAI API key lives in the **Keychain** (`KeychainStore`), never in defaults. New
  saves are device-local and readable only while the user session is unlocked.

## 7. UI (`Transcriber/UI/`)

`MainWindowView` (NavigationSplitView: sessions sidebar | detail) → `LiveSessionView`
(HSplitView: `TranscriptColumnView` | `NotesColumnView`) with banners (detection,
cloud-fallback) above. Toolbar: elapsed clock, level meters (+ mic-unavailable chip),
engine badge (reflects the *actually running* engine), pause/stop/start. `MenuBarExtra`
mirrors session control. Read-only `SessionDetailView` for history. Settings: General /
Transcription / Notes / Account. First-run `OnboardingView` walks permissions and
pre-downloads models. Speaker chips rename via popover; window title is editable while
recording; transcript auto-scrolls with text selection enabled.

## 8. Testing

`TranscriberTests` covers the pure logic: attributor (overlap, watermark pending,
staleness, nearest-fallback, interval merging), text similarity (echo cases from real ASR
output), assembler (ordering, turn grouping, reassign/remove), timeline mapper (identity
and gapped streams), meeting detection state transitions, OpenAI Realtime payload/event
reduction, exporter (content + filename sanitization), Keychain request behavior, and
SwiftData recorder failure paths. Audio/UI paths are verified manually — they require live
TCC grants (see Development hooks in the README).

## 9. Build & dependency locking

`project.yml` is the build source of truth. `Transcriber.xcodeproj` is generated and
ignored, so the repo keeps a canonical root `Package.resolved` and restores it into the
generated Xcode project's SwiftPM location after `xcodegen generate`.

`scripts/sync-package-lock.sh --verify` checks that the generated SwiftPM lockfile still
matches the checked-in lock. See `docs/DEPENDENCIES.md` for the update workflow.
