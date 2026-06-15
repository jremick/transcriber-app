# Roadmap

## Now — finish validating v1

- [ ] **Real-meeting end-to-end test** (Zoom + Google Meet): detection banner → start →
      live speaker-separated transcript → notes → auto-stop → export. All pipeline pieces
      are verified individually with synthetic/local evidence where possible; this is the
      integration pass.
- [ ] **Enable and verify a notes engine** — use Apple Intelligence where available, or
      add an OpenAI key (Settings -> Account), then verify live notes quality and prompt
      edits in a real meeting.
- [ ] **Cloud ASR validation** — exercise `OpenAIRealtimeEngine` against the current
      Realtime API with a real key: session config acceptance, manual-commit timing accuracy,
      reconnect behavior, and the mid-session cloud→local fallback (pull network).
- [ ] **Concurrent-capture hardening** — mic AEC fails (`-10875`/`'!dev'`) when another
      app holds a conflicting input configuration. A controlled Chrome `getUserMedia`
      smoke now verifies the HAL input fallback can start after the AVAudioEngine paths
      fail, including downmix of multi-channel mic-array input. Validate that the
      "You" channel survives real Google Meet/Zoom configurations.
- [ ] **Notifications re-enable flow** — verify the actionable notification path
      (Start Transcribing action) after notification permissions are granted.

## Next — product polish

- [ ] **Jump-to-live pill** when the user scrolls up during a session (auto-scroll
      currently always follows).
- [ ] **Transcript search & per-speaker filter** in live and history views.
- [ ] **Wake/resume UX** — auto-restart capture after sleep instead of staying paused
      (tap + mic engines need a rebuild on wake).
- [ ] **Speaker enrollment / persistent voices** — FluidAudio supports enrollment; "Alex
      from last week" could auto-label across sessions. Privacy-sensitive: keep opt-in.
- [ ] **Action-item extraction** — parse `- [ ]` items from notes into a dedicated
      checklist UI; optional export to Reminders.
- [ ] **More export formats** — plain text, JSON (segments + speakers + times), copy to
      clipboard; per-section export (notes only / transcript only).
- [ ] **Browser meeting confidence** — window-title heuristics (needs Accessibility or
      Screen Recording permission, keep optional) to upgrade "Possible meeting in Chrome"
      to "Google Meet".
- [ ] **Notes engine streaming** — stream Foundation Models / OpenAI output into the notes
      column instead of replacing wholesale per tick.
- [ ] **Locale-aware diarizer variant picker** (LS-EEND `callhome` vs `dihard3`) and a
      max-speakers hint in Settings.

## Later — distribution & scale

- [ ] **Hardened runtime + notarization** for sharing user-installable builds
      (release artifact audit is in `docs/RELEASE_SIGNING_NOTARIZATION.md`; current
      Release build is development-signed, has hardened runtime off, and is rejected by
      Gatekeeper).
- [ ] **Long-meeting soak test** (2h+): memory profile of turns/segments arrays,
      SpeechTranscriber session longevity, SwiftData write amplification.
- [ ] **Performance pass** — Instruments on the audio path (deep-copy rate, resampler
      churn), coalesce volatile UI updates if needed on lower-core machines.
- [ ] **Sparkle (or similar) updates** if distributed.
- [ ] **Localization** of the UI (transcription is already multi-locale).
- [ ] **Audio fixture integration tests** — post-ASR fixture coverage now regression-tests
      attribution, echo suppression, persistence, and export without TCC; canned WAVs still
      need to feed the engine + diarizer offline.
- [ ] **App Store feasibility study** — sandbox-compatible system-audio capture would
      require rearchitecting around ScreenCaptureKit audio; park unless needed.

## Known limitations (accepted for v1)

- Browser detection can't see which site is using the mic → marked "possible meeting".
- Diarization quality depends on remote audio quality; heavy crosstalk can blur clusters.
- AEC quality varies by output device; echo suppression catches the text-level fallout.
- The system tap timeline pauses during silence by design; timestamps come from the
  `TimelineMapper` anchors and can drift ±0.5 s around long silences.
- OpenAI Realtime event schema is isolated in `OpenAIRealtimeEngine` but tracks a moving
  API; expect occasional maintenance.
