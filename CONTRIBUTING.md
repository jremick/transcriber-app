# Contributing

Transcriber is public source-available alpha software. Public issues and focused pull
requests are welcome for bugs, documentation corrections, and small validation fixes.

Larger product, licensing, distribution, or architecture changes should start as an issue
before a pull request. The current priority is honest validation of the local-first macOS
app, not broadening the product surface.

## Before Opening An Issue

- Check [README.md](README.md), [ROADMAP.md](ROADMAP.md), and
  [docs/ALPHA_RELEASE_CHECKLIST.md](docs/ALPHA_RELEASE_CHECKLIST.md) for known limitations.
- Do not include private meeting content, API keys, debug audio, SwiftData stores, local
  logs, or screenshots with personal data.
- Use [SECURITY.md](SECURITY.md) for suspected vulnerabilities instead of public issues.

## Local Verification

Required tools:

- macOS 26 or later on Apple Silicon.
- Xcode 26.
- XcodeGen.

Run:

```sh
xcodegen generate
scripts/sync-package-lock.sh --verify
xcodebuild -scheme Transcriber -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
xcodebuild -scheme Transcriber -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO analyze
```

Model-backed fixture tests are opt-in because they can be slower or environment-dependent:

```sh
TRANSCRIBER_RUN_FLUIDAUDIO_FIXTURE_TESTS=1 xcodebuild -scheme Transcriber -derivedDataPath build -destination 'platform=macOS' test
TRANSCRIBER_RUN_LOCAL_ASR_FIXTURE_TESTS=1 xcodebuild -scheme Transcriber -derivedDataPath build -destination 'platform=macOS' test
```

## Pull Requests

- Keep changes focused and explain the user-visible behavior or validation gap addressed.
- Update docs when behavior, privacy posture, release boundaries, dependencies, or setup
  steps change.
- Do not commit generated Xcode projects, DerivedData, debug audio dumps, diagnostic logs,
  local stores, `.xcarchive`, `.dmg`, `.pkg`, or other generated release artifacts.
- Do not add a distributable binary unless the signing/notarization track in
  [docs/RELEASE_SIGNING_NOTARIZATION.md](docs/RELEASE_SIGNING_NOTARIZATION.md) has been
  completed and documented.
