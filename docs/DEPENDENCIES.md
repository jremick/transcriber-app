# Dependency Management

Version: 0.1.0
Last updated: 2026-06-12

`project.yml` is the build source of truth and `Transcriber.xcodeproj` is generated and
ignored. Because Xcode stores SwiftPM resolution state inside the generated project, this
repo keeps a canonical root `Package.resolved` for reviewable dependency locking.

## Current Swift Packages

| Package | Requirement in `project.yml` | Resolved version | Resolved revision |
|---|---:|---:|---|
| FluidAudio | `from: 0.15.2` | `0.15.2` | `7f963cdc43ba89c5993654f1e138047d517a818d` |

## Lock Workflow

Generate the project:

```sh
xcodegen generate
```

XcodeGen runs `scripts/sync-package-lock.sh --restore` after generation, copying the
checked-in root `Package.resolved` into:

```sh
Transcriber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Verify lock consistency before finishing dependency-sensitive work:

```sh
scripts/sync-package-lock.sh --verify
```

When intentionally updating Swift packages:

1. Edit `project.yml` if the package requirement changes.
2. Run `xcodegen generate`.
3. Resolve or build with Xcode so the generated lock updates.
4. Review the generated lock diff.
5. Run:

```sh
scripts/sync-package-lock.sh --update
scripts/sync-package-lock.sh --verify
```

Commit `project.yml`, root `Package.resolved`, and any relevant notes together.

Do not commit `Transcriber.xcodeproj`; it remains generated state.
