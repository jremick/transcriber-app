#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scheme="${SCHEME:-Transcriber}"
configuration="${CONFIGURATION:-Release}"
app_name="${APP_NAME:-Transcriber}"
derived_data_path="${DERIVED_DATA_PATH:-$root_dir/build}"
dist_dir="${DIST_DIR:-$root_dir/dist/alpha}"

if [[ "$derived_data_path" != /* ]]; then
  derived_data_path="$root_dir/$derived_data_path"
fi

if [[ "$dist_dir" != /* ]]; then
  dist_dir="$root_dir/$dist_dir"
fi

app_path="$derived_data_path/Build/Products/$configuration/$app_name.app"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
artifact_stem="${ARTIFACT_STEM:-Transcriber-alpha-$timestamp-local-dev-signed}"
zip_path="$dist_dir/$artifact_stem.zip"
metadata_path="$dist_dir/$artifact_stem-validation.txt"
checksums_path="$dist_dir/$artifact_stem-SHA256SUMS.txt"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcriber-alpha.XXXXXX")"

trap 'rm -rf "$tmp_dir"' EXIT

usage() {
  cat <<'EOF'
Usage: scripts/build-alpha-release.sh

Builds a Release alpha candidate, validates local signing, records Gatekeeper
assessment, and writes:

  dist/alpha/Transcriber-alpha-<timestamp>-local-dev-signed.zip
  dist/alpha/Transcriber-alpha-<timestamp>-local-dev-signed-validation.txt
  dist/alpha/Transcriber-alpha-<timestamp>-local-dev-signed-SHA256SUMS.txt

Environment overrides:
  SCHEME, CONFIGURATION, APP_NAME, DERIVED_DATA_PATH, DIST_DIR, ARTIFACT_STEM

This script does not notarize or staple the app. Gatekeeper rejection is recorded
as a warning for local/development-signed alpha artifacts.
EOF
}

log() {
  printf '[alpha-release] %s\n' "$*"
}

fail() {
  printf '[alpha-release] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
}

capture_command() {
  local name="$1"
  shift

  local out_file="$tmp_dir/$name.txt"
  local rc_file="$tmp_dir/$name.rc"
  local rc=0

  "$@" >"$out_file" 2>&1 || rc=$?
  printf '%s\n' "$rc" >"$rc_file"
}

command_rc() {
  local name="$1"
  cat "$tmp_dir/$name.rc"
}

status_for_rc() {
  local rc="$1"
  if [[ "$rc" == "0" ]]; then
    printf 'PASS'
  else
    printf 'FAIL'
  fi
}

append_output_block() {
  local title="$1"
  local file="$2"

  {
    printf '\n%s\n' "$title"
    printf '%s\n' "----------------------------------------"
    if [[ -s "$file" ]]; then
      sed 's/^/  /' "$file"
    else
      printf '  (no output)\n'
    fi
  } >>"$metadata_path"
}

plist_value() {
  local key="$1"
  local plist="$2"

  if [[ -x /usr/libexec/PlistBuddy && -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
  fi
}

bool_from_status_file() {
  local file="$1"
  if [[ -s "$file" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

write_metadata() {
  local zip_sha="$1"
  local zip_created="$2"
  local checksums_created="$3"
  local validation_failed="$4"
  local bundle_scan_status="$5"
  local bundle_scan_count="$6"
  local codesign_verify_rc="$7"
  local codesign_inspect_rc="$8"
  local spctl_rc="$9"
  local signing_mode="${10}"
  local hardened_runtime="${11}"
  local get_task_allow="${12}"
  local bundle_id="${13}"
  local bundle_version="${14}"
  local build_version="${15}"
  local git_commit="${16}"
  local git_dirty="${17}"
  local git_dirty_entries="${18}"

  local root_name
  local zip_filename
  local checksums_filename
  local app_path_relative
  local derived_data_relative

  root_name="$(basename "$root_dir")"
  zip_filename="${zip_path##*/}"
  checksums_filename="${checksums_path##*/}"
  app_path_relative="${app_path#"$root_dir/"}"
  if [[ "$app_path_relative" == "$app_path" ]]; then
    app_path_relative="build/Build/Products/$configuration/$app_name.app"
  fi
  derived_data_relative="$derived_data_path"
  if [[ "$derived_data_relative" == "$root_dir/"* ]]; then
    derived_data_relative="${derived_data_relative#"$root_dir/"}"
  else
    derived_data_relative="$(basename "$derived_data_relative")"
  fi

  local codesign_verify_status
  local codesign_inspect_status
  local spctl_status

  codesign_verify_status="$(status_for_rc "$codesign_verify_rc")"
  codesign_inspect_status="$(status_for_rc "$codesign_inspect_rc")"
  if [[ "$spctl_rc" == "0" ]]; then
    spctl_status="PASS"
  else
    spctl_status="WARN"
  fi

  cat >"$metadata_path" <<EOF
Transcriber Alpha Release Candidate
Created UTC: $timestamp
Source root: $root_name (local path omitted)
Git commit: $git_commit
Working tree dirty: $git_dirty
Working tree status entries: $git_dirty_entries

Artifact
Zip created: $zip_created
Zip path: $zip_filename
Zip SHA256: $zip_sha
Checksums created: $checksums_created
Checksums path: $checksums_filename
Bundle path: $app_path_relative
Bundle identifier: ${bundle_id:-unknown}
Bundle short version: ${bundle_version:-unset}
Bundle build version: ${build_version:-unset}

Build
Scheme: $scheme
Configuration: $configuration
Derived data path: $derived_data_relative
Build source of truth: project.yml
Prebuild steps:
- xcodegen generate
- scripts/sync-package-lock.sh --verify
- xcodebuild -scheme $scheme -derivedDataPath $derived_data_relative -configuration $configuration build

Release Boundary
Alpha type: local/dev-signed candidate for private testing
Notarization: NOT PERFORMED
Stapling: NOT PERFORMED
Public binary readiness: NO unless signing/notarization validation is added later
Gatekeeper policy: spctl rejection is recorded as WARN, not as a packaging failure, because development-signed/non-notarized alpha builds can be rejected.

Packaging Exclusions
Zip source: built .app bundle only
Repository work directories included: no
Build logs included: no
Derived data included outside app bundle: no
Debug audio dumps included: no
Secret/env files included: no
Bundle sensitive-file scan: $bundle_scan_status
Bundle sensitive-file matches: $bundle_scan_count

Signing Summary
Signing mode: $signing_mode
Hardened runtime: $hardened_runtime
get-task-allow entitlement: $get_task_allow
codesign verify: $codesign_verify_status (exit $codesign_verify_rc)
codesign inspect/entitlements: $codesign_inspect_status (exit $codesign_inspect_rc)
spctl execute assessment: $spctl_status (exit $spctl_rc)

Validation Result
Required validation failed: $validation_failed
EOF

  if [[ "$bundle_scan_count" != "0" ]]; then
    append_output_block "Sensitive Bundle Scan Matches" "$tmp_dir/sensitive-files.txt"
  fi

  append_output_block "codesign --verify --deep --strict --verbose=4" "$tmp_dir/codesign-verify.txt"
  append_output_block "codesign -dvvv --entitlements :-" "$tmp_dir/codesign-inspect.txt"
  append_output_block "spctl -a -vv --type execute" "$tmp_dir/spctl.txt"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command spctl
require_command ditto
require_command shasum

mkdir -p "$dist_dir"

log "Generating Xcode project from project.yml"
(cd "$root_dir" && xcodegen generate)

log "Verifying SwiftPM lockfile"
(cd "$root_dir" && "$root_dir/scripts/sync-package-lock.sh" --verify)

log "Building $scheme $configuration"
(cd "$root_dir" && xcodebuild -scheme "$scheme" -derivedDataPath "$derived_data_path" -configuration "$configuration" build)

[[ -d "$app_path" ]] || fail "Expected app bundle was not created at $app_path"
[[ -f "$app_path/Contents/Info.plist" ]] || fail "App bundle is missing Contents/Info.plist"

log "Scanning app bundle for files that should not ship in an alpha zip"
find "$app_path" \
  \( \
    -type d \( -name work -o -name DerivedData -o -name build -o -name Logs \) \
    -o -type f \( \
      -iname '*.wav' \
      -o -iname '*.caf' \
      -o -iname '*.aiff' \
      -o -iname '*.aif' \
      -o -iname '*.mp3' \
      -o -iname '*.m4a' \
      -o -iname '*.log' \
      -o -iname '*.xcresult' \
      -o -iname '.env' \
      -o -iname '.env.*' \
      -o -iname '*debugAudioDump*' \
      -o -iname '*debug-audio*' \
    \) \
  \) \
  -print >"$tmp_dir/sensitive-files.txt"

bundle_scan_count="$(wc -l <"$tmp_dir/sensitive-files.txt" | tr -d ' ')"
bundle_scan_status="PASS"
validation_failed="no"
if [[ "$bundle_scan_count" != "0" ]]; then
  bundle_scan_status="FAIL"
  validation_failed="yes"
fi

log "Validating code signature"
capture_command codesign-verify codesign --verify --deep --strict --verbose=4 "$app_path"
capture_command codesign-inspect codesign -dvvv --entitlements :- "$app_path"

log "Running Gatekeeper assessment"
capture_command spctl spctl -a -vv --type execute "$app_path"

codesign_verify_rc="$(command_rc codesign-verify)"
codesign_inspect_rc="$(command_rc codesign-inspect)"
spctl_rc="$(command_rc spctl)"

if [[ "$codesign_verify_rc" != "0" || "$codesign_inspect_rc" != "0" ]]; then
  validation_failed="yes"
fi

signing_mode="unknown"
if grep -q '^Authority=Developer ID Application' "$tmp_dir/codesign-inspect.txt"; then
  signing_mode="Developer ID Application"
elif grep -q '^Authority=Apple Development' "$tmp_dir/codesign-inspect.txt"; then
  signing_mode="Apple Development"
elif grep -q '^Authority=' "$tmp_dir/codesign-inspect.txt"; then
  signing_mode="other signed identity"
fi

hardened_runtime="not detected"
if grep -q '^Runtime Version=' "$tmp_dir/codesign-inspect.txt"; then
  hardened_runtime="detected"
fi

get_task_allow="not present"
if grep -A1 'com.apple.security.get-task-allow' "$tmp_dir/codesign-inspect.txt" | grep -q '<true/>'; then
  get_task_allow="true"
elif grep -A1 'com.apple.security.get-task-allow' "$tmp_dir/codesign-inspect.txt" | grep -q '<false/>'; then
  get_task_allow="false"
fi

info_plist="$app_path/Contents/Info.plist"
bundle_id="$(plist_value CFBundleIdentifier "$info_plist")"
bundle_version="$(plist_value CFBundleShortVersionString "$info_plist")"
build_version="$(plist_value CFBundleVersion "$info_plist")"

git_commit="$(git -C "$root_dir" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
git -C "$root_dir" status --porcelain >"$tmp_dir/git-status.txt" 2>/dev/null || true
git_dirty="$(bool_from_status_file "$tmp_dir/git-status.txt")"
git_dirty_entries="$(wc -l <"$tmp_dir/git-status.txt" | tr -d ' ')"

zip_created="no"
checksums_created="no"
zip_sha="not created"

rm -f "$zip_path" "$metadata_path" "$checksums_path"

if [[ "$validation_failed" == "no" ]]; then
  log "Creating alpha zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
  zip_created="yes"
  zip_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
else
  log "Required validation failed; metadata will be written without creating a zip"
fi

write_metadata \
  "$zip_sha" \
  "$zip_created" \
  "$checksums_created" \
  "$validation_failed" \
  "$bundle_scan_status" \
  "$bundle_scan_count" \
  "$codesign_verify_rc" \
  "$codesign_inspect_rc" \
  "$spctl_rc" \
  "$signing_mode" \
  "$hardened_runtime" \
  "$get_task_allow" \
  "$bundle_id" \
  "$bundle_version" \
  "$build_version" \
  "$git_commit" \
  "$git_dirty" \
  "$git_dirty_entries"

if [[ "$validation_failed" == "yes" ]]; then
  fail "Required validation failed. See $metadata_path"
fi

log "Writing SHA256 checksums"
(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$zip_path")" "$(basename "$metadata_path")" >"$(basename "$checksums_path")"
)
checksums_created="yes"

write_metadata \
  "$zip_sha" \
  "$zip_created" \
  "$checksums_created" \
  "$validation_failed" \
  "$bundle_scan_status" \
  "$bundle_scan_count" \
  "$codesign_verify_rc" \
  "$codesign_inspect_rc" \
  "$spctl_rc" \
  "$signing_mode" \
  "$hardened_runtime" \
  "$get_task_allow" \
  "$bundle_id" \
  "$bundle_version" \
  "$build_version" \
  "$git_commit" \
  "$git_dirty" \
  "$git_dirty_entries"

log "Alpha release candidate created"
log "Zip: $zip_path"
log "Metadata: $metadata_path"
log "Checksums: $checksums_path"

if [[ "$spctl_rc" != "0" ]]; then
  log "Gatekeeper did not accept this app. That status is recorded as WARN because this script does not notarize alpha artifacts."
fi
