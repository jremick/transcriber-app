#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root_lock="$root_dir/Package.resolved"
generated_lock="$root_dir/Transcriber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

usage() {
  cat <<'EOF'
Usage: scripts/sync-package-lock.sh [--restore|--verify|--update]

  --restore  Copy the checked-in Package.resolved into the generated Xcode project.
  --verify   Compare the generated Xcode project lockfile with the checked-in lockfile.
  --update   Copy the generated Xcode project lockfile back to the checked-in lockfile.

Run --update only after intentionally resolving/updating Swift packages.
EOF
}

mode="${1:---verify}"

case "$mode" in
  --restore)
    if [[ ! -f "$root_lock" ]]; then
      echo "Missing checked-in Package.resolved at $root_lock" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$generated_lock")"
    cp "$root_lock" "$generated_lock"
    echo "Restored generated SwiftPM lockfile from Package.resolved"
    ;;
  --verify)
    if [[ ! -f "$root_lock" ]]; then
      echo "Missing checked-in Package.resolved at $root_lock" >&2
      exit 1
    fi
    if [[ ! -f "$generated_lock" ]]; then
      echo "Missing generated lockfile at $generated_lock; run xcodegen generate first." >&2
      exit 1
    fi
    if ! cmp -s "$root_lock" "$generated_lock"; then
      echo "SwiftPM lockfile drift detected." >&2
      echo "Review package changes, then run scripts/sync-package-lock.sh --update if intentional." >&2
      diff -u "$root_lock" "$generated_lock" >&2 || true
      exit 1
    fi
    echo "SwiftPM lockfile matches Package.resolved"
    ;;
  --update)
    if [[ ! -f "$generated_lock" ]]; then
      echo "Missing generated lockfile at $generated_lock; run xcodegen generate and resolve packages first." >&2
      exit 1
    fi
    cp "$generated_lock" "$root_lock"
    echo "Updated checked-in Package.resolved from generated SwiftPM lockfile"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
