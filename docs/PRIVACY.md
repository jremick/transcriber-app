# Privacy Model

Version: 0.1.0
Last updated: 2026-06-12

Transcriber is local-first. The default path captures meeting audio on the local Mac,
converts it to transcript text, identifies speakers locally, and persists transcript data
only.

## Local By Default

- Microphone audio is captured locally through AVAudioEngine.
- System audio is captured locally through a Core Audio process tap.
- On-device transcription uses Apple SpeechAnalyzer / SpeechTranscriber.
- Remote speaker diarization always runs locally with FluidAudio.
- On-device notes use Apple Foundation Models when Apple Intelligence is available.
- Local extractive notes use only transcript text already generated inside the app and do
  not call a model or network service.
- Meeting detection uses local Core Audio process state to identify apps that are actively
  using the microphone. Browser meetings remain "possible meeting" signals because the app
  does not inspect page content.

## Persisted Data

SwiftData history stores:

- Session title, source app name, start/end time, duration, and ASR engine used.
- Final transcript segments with speaker labels, timestamps, source, and text.
- Per-session speaker names and colors.
- Notes Markdown and the notes prompt used.

The app does not persist meeting audio by default. Volatile transcript text is not saved
until it finalizes into transcript segments.

If the app is relaunched after a crash, unfinished empty sessions are discarded and
unfinished sessions with transcript rows are closed at the last segment timestamp. Repair
failures are surfaced through the app error alert instead of being ignored.

On this development build, SwiftData uses the app's default Application Support store. The
exact path can vary by build/signing/container state; the current unsandboxed debug build
has been observed using `~/Library/Application Support/default.store`.

## OpenAI Cloud Paths

OpenAI is optional and requires an API key saved in the app's Keychain item.

- Cloud ASR sends microphone and system audio to OpenAI Realtime when the transcription
  engine is set to OpenAI. Speaker diarization still stays local.
- Cloud notes send the current notes and new transcript text to the OpenAI Responses API.
- OpenAI notes requests include `store: false`.
- Automatic notes mode uses Apple on-device notes when available, OpenAI only when
  on-device notes are unavailable and an API key is saved, then local extractive notes.

The OpenAI API key is stored in Keychain under the app service/account and is not written to
UserDefaults, SwiftData, debug logs, or repo files. New saves use
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so the key is device-local and readable only
while the user session is unlocked. Updating an existing key uses `SecItemUpdate` in place
rather than deleting the old item before the new save succeeds.

## Debug Artifacts

Debug artifacts are local and opt-in through UserDefaults.

| Default key | Default | Data written |
|---|---:|---|
| `debugAudioDump` | Off | Per-stream WAV files containing meeting audio |
| `debugDiag` | Off in a fresh defaults domain | Local pipeline diagnostics in `diag.log` |
| `debugAutoStart` | Off | No data by itself; starts recording automatically at launch |

Debug files are written under:

```sh
~/Library/Application Support/Transcriber/debug/
```

Useful cleanup commands:

```sh
defaults write dev.local.transcriber debugAudioDump -bool NO
defaults write dev.local.transcriber debugAutoStart -bool NO
rm -f "$HOME/Library/Application Support/Transcriber/debug/"*.wav
rm -f "$HOME/Library/Application Support/Transcriber/debug/diag.log"
```

Settings -> General -> Diagnostics shows whether debug audio dumps or diagnostics are on
and provides direct reveal and delete actions for the debug folder. The in-app delete action
removes known debug artifacts only: `*.wav` files and `diag.log`.

## Permissions

The app requests:

- Microphone: required to transcribe the local speaker.
- System Audio Recording: required for remote participants captured through the process tap.
- Notifications: optional prompt path for detected meetings.

If notifications are denied, the app still shows the in-app detection banner and menu bar
fallback.

## Current Alpha Limitations

- Real-meeting proof is still open until a live Google Meet or Zoom run verifies
  detection, start, capture, transcript, notes, stop, persistence, and export.
- Automatic notes can fall back to local extractive notes when Apple on-device notes are
  unavailable and no OpenAI key is saved, but notes quality still needs verification in a
  real meeting run.
- OpenAI Realtime ASR has been updated to the current documented session shape, but no
  API-key-backed live cloud ASR run has been completed.
- Development signing and hardened runtime settings are not production distribution
  settings; see `docs/RELEASE_SIGNING_NOTARIZATION.md` for the current artifact audit and
  release track plan.
