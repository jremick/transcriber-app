# Release Signing And Notarization Plan

Version: 0.1.0
Last updated: 2026-06-12

## Scope

This document records the current distribution-readiness audit for Transcriber. It does not
move public binary distribution into v1. The v1 milestone remains real-meeting reliability;
notarized distribution is a later release track.

## Artifact Audited

Release build command:

```sh
xcodebuild -scheme Transcriber -derivedDataPath build -configuration Release build
```

Audited artifact:

```sh
build/Build/Products/Release/Transcriber.app
```

Do not use the app bundle left behind by `xcodebuild test` for distribution-signing
conclusions. The test-hosted debug bundle can include XCTest plug-ins/frameworks and
temporary test entitlements that are not representative of a distributable app.

## Current Release Build State

- Release build succeeded.
- Bundle identifier: `dev.local.transcriber`.
- Binary architecture: universal `x86_64 arm64`.
- Code signature verifies on disk and satisfies its designated requirement.
- Signing identity: local development/ad-hoc signing only; no distribution identity is
  checked in or required for source builds.
- CodeDirectory flags: `0x0(none)`, so hardened runtime is not enabled.
- Entitlements on the Release app contain `com.apple.security.get-task-allow = true`.
- App Sandbox is not enabled; no `com.apple.security.app-sandbox` entitlement is present.
- Gatekeeper assessment can reject current local alpha artifacts:
  - `spctl -a -vv --type execute build/Build/Products/Release/Transcriber.app`
- Expected result before notarization: rejection or warning, depending on local signing.
- Info.plist includes the required TCC purpose strings for microphone, system audio capture,
  and speech recognition.

## Distribution Gaps

The current Release product is suitable for local development validation only. It is not
ready to publish as a user-installable binary because:

- It is not signed with a published Developer ID Application identity.
- Hardened runtime is disabled.
- `get-task-allow` is enabled.
- It has not been archived, exported, notarized, or stapled.
- Gatekeeper rejects the current Release app.
- Sandbox feasibility has not been proven against the app's system-audio process tap,
  microphone HAL fallback, SpeechTranscriber, FluidAudio model loading, SwiftData storage,
  Keychain access, and export save panel paths.

## Release Track Plan

When distribution becomes in scope:

1. Keep development and distribution settings separate.
   - Continue using local development settings for TCC/audio iteration.
   - Add a dedicated distribution configuration or explicit archive/export settings rather
     than overloading the debug/development path.
2. Add or select a Developer ID Application signing identity.
   - Verify with `security find-identity -p codesigning -v`.
   - Do not proceed until a `Developer ID Application` identity is available.
3. Enable hardened runtime for the distribution artifact.
   - Verify `codesign -dvvv` reports the runtime flag.
   - Start with the narrowest runtime exceptions possible; add entitlements only when a
     runtime smoke proves they are required.
4. Ensure distribution entitlements are clean.
   - `com.apple.security.get-task-allow` must be absent or false.
   - Do not enable App Sandbox unless a separate feasibility pass proves that capture,
     model loading, persistence, Keychain, and export all still work.
5. Archive and export the app.
   - Use an `.xcarchive` as the source artifact.
   - Use a checked-in export options file only after the intended distribution method is
     decided.
6. Notarize and staple.
   - Submit the exported app or zip with `xcrun notarytool`.
   - Staple the successful ticket with `xcrun stapler`.
7. Validate the final artifact.
   - `codesign --verify --deep --strict --verbose=4 <app>`
   - `codesign -dvvv --entitlements :- <app>`
   - `spctl -a -vv --type execute <app>`
   - `xcrun stapler validate <app>`
8. Run a fresh-app smoke from the exported artifact.
   - Verify launch.
   - Verify first-run TCC prompts or existing permission behavior.
   - Verify microphone capture, system audio capture, local ASR, diarization, stop,
     persistence, export, Keychain save/read, and OpenAI-disabled local defaults.

## Not Verified

- No Developer ID signed artifact was produced or published.
- No notarization submission was attempted.
- No stapled artifact was validated.
- No sandboxed artifact was built or smoke-tested.
- No exported `.xcarchive` or `.pkg`/`.dmg` distribution flow was created.
