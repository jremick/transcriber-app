# Changelog

## Unreleased

- Added an alpha release checklist for source-available/public-alpha release preparation.
- Added candidate GitHub release notes for `v0.1.0-alpha.1`.

## Candidate v0.1.0-alpha.1 release notes - 2026-06-14

No GitHub tag or release has been published for this candidate yet.

This is an honest source-available public alpha for the native macOS Transcriber app. It is
intended to preserve the current working state for continued real-meeting validation, not
to claim a notarized distributable binary.

### Included

- Local-first macOS 26+ meeting transcription app with microphone capture, system audio
  capture, local Apple Speech transcription, local FluidAudio diarization, SwiftData
  transcript history, Markdown export, and a menu bar presence.
- Optional OpenAI paths for Realtime ASR and Responses-based notes, with API keys stored in
  Keychain and OpenAI notes requests configured with response storage disabled.
- Automatic notes can use Apple on-device notes when available, OpenAI only when a saved key
  exists, or a local extractive fallback.
- Meeting detection covers known meeting apps and browser microphone activity, including a
  conservative "possible meeting" path for browsers.
- Privacy documentation, dependency locking notes, release checklist, and release
  signing/notarization notes are included.

### Verification Evidence

- Local unit and fixture coverage exists for transcript assembly, diarizer lifecycle,
  bounded audio buffering, persistence/export behavior, OpenAI request shaping and fallback
  seams, dependency lock verification, and model fixture probes.
- Controlled local smokes have exercised capture startup, browser detection, degraded
  capture UI, export, and launch behavior on the development Mac.
- The current Release app artifact was audited and verifies on disk, but that does not make
  it suitable for distribution.

### Known Limitations

- Real Google Meet or Zoom proof is deferred. A live meeting still needs to verify
  detection, start, microphone/system capture, live speaker attribution, notes, stop,
  persistence, and export.
- OpenAI live ASR has not been verified with an API key against the service.
- Notes quality has not been verified in a real meeting.
- Generated and controlled fixtures do not prove live ASR quality, FluidAudio diarization
  accuracy, multi-speaker separation, or long-session UI/memory behavior.
- The app remains macOS 26+ and local-first.

### Distribution Status

- This alpha should be treated as source-available alpha only.
- Current local Release artifacts are development/ad-hoc signed, have hardened runtime off,
  may keep development entitlements, and are expected to be rejected by Gatekeeper unless a
  separate distribution-signing pass is completed.
- No Developer ID signed artifact is published.
- No notarized or stapled artifact exists.
- Do not present the current app bundle as a user-installable public binary.
