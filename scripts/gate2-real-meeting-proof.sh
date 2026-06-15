#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="dev.local.transcriber"
app_path="$root_dir/build/Build/Products/Debug/Transcriber.app"
work_root="$root_dir/work/gate2-proof"
current_run_file="$work_root/current-run-dir"
store_path="$HOME/Library/Application Support/default.store"
keychain_service="dev.local.transcriber"
keychain_account="openai-api-key"

usage() {
  cat <<'EOF'
Usage: scripts/gate2-real-meeting-proof.sh <preflight|start|summarize|verify-export|reset-debug-defaults>

  preflight             Record local environment, TCC/defaults, and latest session metadata.
  start                 Run preflight, force safe debug defaults, and launch the debug app.
  summarize             Record latest persisted session metadata and Gate 2 checks.
  verify-export PATH    Verify a Markdown export saved through the app without printing text.
  reset-debug-defaults  Turn off auto-start and debug audio dumps.

The script writes local evidence under work/gate2-proof/ and intentionally does not print
or copy transcript text, API keys, debug WAVs, or full diagnostic logs.
EOF
}

new_run_dir() {
  mkdir -p "$work_root"
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  local dir="$work_root/run-$stamp"
  mkdir -p "$dir"
  printf '%s\n' "$dir" > "$current_run_file"
  printf '%s\n' "$dir"
}

current_run_dir() {
  if [[ -f "$current_run_file" ]]; then
    local dir
    dir="$(cat "$current_run_file")"
    if [[ -d "$dir" ]]; then
      printf '%s\n' "$dir"
      return
    fi
  fi
  new_run_dir
}

bool_default() {
  local key="$1"
  if value="$(defaults read "$bundle_id" "$key" 2>/dev/null)"; then
    printf '%s=%s\n' "$key" "$value"
  else
    printf '%s=unset\n' "$key"
  fi
}

write_tcc_status() {
  local out="$1"
  local tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  {
    printf 'TCC status for %s\n' "$bundle_id"
    if [[ ! -r "$tcc_db" ]]; then
      printf 'TCC database not readable at %s\n' "$tcc_db"
      return
    fi
    sqlite3 -header -column "$tcc_db" <<SQL
SELECT service, auth_value, auth_reason, last_modified
FROM access
WHERE client = '$bundle_id'
  AND service IN ('kTCCServiceMicrophone', 'kTCCServiceAudioCapture')
ORDER BY service;
SQL
  } > "$out"
}

write_latest_session() {
  local out="$1"
  {
    printf 'Latest SwiftData session metadata\n'
    printf 'Store: %s\n\n' "$store_path"
    if [[ ! -f "$store_path" ]]; then
      printf 'No SwiftData store found.\n'
      return
    fi
    sqlite3 -header -column "$store_path" <<'SQL'
SELECT
  s.Z_PK AS pk,
  length(COALESCE(s.ZTITLE, '')) AS title_chars,
  COALESCE(s.ZSOURCEAPPNAME, '') AS source_app,
  s.ZASRENGINEUSED AS asr_engine,
  printf('%.2f', s.ZDURATION) AS duration_seconds,
  CASE WHEN s.ZENDEDAT IS NULL THEN 'no' ELSE 'yes' END AS ended,
  length(COALESCE(s.ZNOTESMARKDOWN, '')) AS notes_chars,
  (SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD t WHERE t.ZSESSION = s.Z_PK) AS segments,
  (SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD t WHERE t.ZSESSION = s.Z_PK AND t.ZSOURCE = 'microphone') AS mic_segments,
  (SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD t WHERE t.ZSESSION = s.Z_PK AND t.ZSOURCE = 'system') AS system_segments,
  (SELECT count(DISTINCT t.ZSPEAKERKEY) FROM ZTRANSCRIPTSEGMENTRECORD t WHERE t.ZSESSION = s.Z_PK) AS transcript_speakers,
  (SELECT count(*) FROM ZSPEAKERRECORD r WHERE r.ZSESSION = s.Z_PK) AS speaker_rows
FROM ZMEETINGSESSION s
ORDER BY s.Z_PK DESC
LIMIT 1;
SQL
  } > "$out"
}

sqlite_scalar() {
  local sql="$1"
  if [[ ! -f "$store_path" ]]; then
    printf ''
    return
  fi
  sqlite3 "$store_path" "$sql" 2>/dev/null || printf ''
}

latest_session_pk() {
  if [[ ! -f "$store_path" ]]; then
    printf '0\n'
    return
  fi
  sqlite3 "$store_path" "SELECT COALESCE(MAX(Z_PK), 0) FROM ZMEETINGSESSION;" 2>/dev/null || printf '0\n'
}

latest_session_metric() {
  local metric="$1"
  case "$metric" in
    duration)
      sqlite_scalar "SELECT printf('%.2f', COALESCE(ZDURATION, 0)) FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
    ended)
      sqlite_scalar "SELECT CASE WHEN ZENDEDAT IS NULL THEN 'no' ELSE 'yes' END FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
    notes_chars)
      sqlite_scalar "SELECT length(COALESCE(ZNOTESMARKDOWN, '')) FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
    segments)
      sqlite_scalar "SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD WHERE ZSESSION = (SELECT MAX(Z_PK) FROM ZMEETINGSESSION);"
      ;;
    mic_segments)
      sqlite_scalar "SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD WHERE ZSESSION = (SELECT MAX(Z_PK) FROM ZMEETINGSESSION) AND ZSOURCE = 'microphone';"
      ;;
    system_segments)
      sqlite_scalar "SELECT count(*) FROM ZTRANSCRIPTSEGMENTRECORD WHERE ZSESSION = (SELECT MAX(Z_PK) FROM ZMEETINGSESSION) AND ZSOURCE = 'system';"
      ;;
    transcript_speakers)
      sqlite_scalar "SELECT count(DISTINCT ZSPEAKERKEY) FROM ZTRANSCRIPTSEGMENTRECORD WHERE ZSESSION = (SELECT MAX(Z_PK) FROM ZMEETINGSESSION);"
      ;;
    source_app)
      sqlite_scalar "SELECT COALESCE(ZSOURCEAPPNAME, '') FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
    asr_engine)
      sqlite_scalar "SELECT COALESCE(ZASRENGINEUSED, '') FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
    title_chars)
      sqlite_scalar "SELECT length(COALESCE(ZTITLE, '')) FROM ZMEETINGSESSION ORDER BY Z_PK DESC LIMIT 1;"
      ;;
  esac
}

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

write_check_line() {
  local out="$1"
  local status="$2"
  local name="$3"
  local detail="$4"
  printf '%s\t%s\t%s\n' "$status" "$name" "$detail" >> "$out"
}

write_gate2_checks() {
  local out="$1"
  local before_pk="$2"
  local after_pk="$3"
  : > "$out"

  local failures=0
  local warnings=0
  local ended duration notes_chars segments mic_segments system_segments transcript_speakers source_app asr_engine
  ended="$(latest_session_metric ended)"
  duration="$(latest_session_metric duration)"
  notes_chars="$(latest_session_metric notes_chars)"
  segments="$(latest_session_metric segments)"
  mic_segments="$(latest_session_metric mic_segments)"
  system_segments="$(latest_session_metric system_segments)"
  transcript_speakers="$(latest_session_metric transcript_speakers)"
  source_app="$(latest_session_metric source_app)"
  asr_engine="$(latest_session_metric asr_engine)"

  if is_int "$before_pk" && is_int "$after_pk" && (( after_pk > before_pk )); then
    write_check_line "$out" PASS "new session persisted" "before_pk=$before_pk after_pk=$after_pk"
  else
    write_check_line "$out" FAIL "new session persisted" "before_pk=$before_pk after_pk=$after_pk"
    failures=$((failures + 1))
  fi

  if [[ "$ended" == "yes" ]]; then
    write_check_line "$out" PASS "session ended" "ended=$ended duration_seconds=$duration"
  else
    write_check_line "$out" FAIL "session ended" "ended=${ended:-unknown} duration_seconds=${duration:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$segments" && (( segments > 0 )); then
    write_check_line "$out" PASS "transcript rows present" "segments=$segments"
  else
    write_check_line "$out" FAIL "transcript rows present" "segments=${segments:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$mic_segments" && (( mic_segments > 0 )); then
    write_check_line "$out" PASS "microphone channel persisted" "mic_segments=$mic_segments"
  else
    write_check_line "$out" FAIL "microphone channel persisted" "mic_segments=${mic_segments:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$system_segments" && (( system_segments > 0 )); then
    write_check_line "$out" PASS "system channel persisted" "system_segments=$system_segments"
  else
    write_check_line "$out" FAIL "system channel persisted" "system_segments=${system_segments:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$transcript_speakers" && (( transcript_speakers >= 2 )); then
    write_check_line "$out" PASS "speaker attribution has multiple speakers" "transcript_speakers=$transcript_speakers"
  else
    write_check_line "$out" FAIL "speaker attribution has multiple speakers" "transcript_speakers=${transcript_speakers:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$notes_chars" && (( notes_chars > 0 )); then
    write_check_line "$out" PASS "notes updated" "notes_chars=$notes_chars"
  else
    write_check_line "$out" FAIL "notes updated" "notes_chars=${notes_chars:-unknown}"
    failures=$((failures + 1))
  fi

  if [[ -n "$source_app" ]]; then
    write_check_line "$out" PASS "detected source app recorded" "source_app=$source_app"
  else
    write_check_line "$out" WARN "detected source app recorded" "source_app empty; manual start may be intentional"
    warnings=$((warnings + 1))
  fi

  if [[ -n "$asr_engine" ]]; then
    write_check_line "$out" PASS "ASR engine recorded" "asr_engine=$asr_engine"
  else
    write_check_line "$out" FAIL "ASR engine recorded" "asr_engine empty"
    failures=$((failures + 1))
  fi

  printf 'failures=%s warnings=%s\n' "$failures" "$warnings" >> "$out"
  return "$failures"
}

clock_for_seconds() {
  local seconds="${1:-0}"
  awk -v seconds="$seconds" 'BEGIN {
    s = int(seconds)
    h = int(s / 3600)
    m = int((s % 3600) / 60)
    sec = s % 60
    if (h > 0) {
      printf "%d:%02d:%02d\n", h, m, sec
    } else {
      printf "%02d:%02d\n", m, sec
    }
  }'
}

write_export_checks() {
  local export_path="$1"
  local out="$2"
  : > "$out"

  local failures=0
  local warnings=0
  local segments notes_chars duration source_app title_chars duration_clock
  segments="$(latest_session_metric segments)"
  notes_chars="$(latest_session_metric notes_chars)"
  duration="$(latest_session_metric duration)"
  source_app="$(latest_session_metric source_app)"
  title_chars="$(latest_session_metric title_chars)"
  duration_clock="$(clock_for_seconds "${duration:-0}")"

  if [[ ! -f "$export_path" ]]; then
    write_check_line "$out" FAIL "export file exists" "path=$export_path"
    printf 'failures=1 warnings=0\n' >> "$out"
    return 1
  fi

  local bytes lines first_line transcript_lines export_speakers
  bytes="$(wc -c < "$export_path" | tr -d '[:space:]')"
  lines="$(wc -l < "$export_path" | tr -d '[:space:]')"
  first_line="$(sed -n '1p' "$export_path")"
  transcript_lines="$(grep -Ec '^\*\*.+\*\* \[[0-9:]+\]: ' "$export_path" || true)"
  export_speakers="$(
    awk '/^\*\*.+\*\* \[[0-9:]+\]: / {
      line = $0
      sub(/^\*\*/, "", line)
      sub(/\*\* \[[0-9:]+\]: .*/, "", line)
      if (!(line in seen)) {
        seen[line] = 1
        count++
      }
    } END { print count + 0 }' "$export_path"
  )"

  write_check_line "$out" PASS "export file exists" "path=$export_path bytes=$bytes lines=$lines"

  if [[ "$first_line" == \#\ * ]]; then
    write_check_line "$out" PASS "export has title heading" "title_chars_latest_session=${title_chars:-unknown}"
  else
    write_check_line "$out" FAIL "export has title heading" "first_line_missing_markdown_h1"
    failures=$((failures + 1))
  fi

  if grep -Fq -- "- **Duration:** $duration_clock" "$export_path"; then
    write_check_line "$out" PASS "export duration matches latest session" "duration=$duration_clock"
  else
    write_check_line "$out" FAIL "export duration matches latest session" "expected_duration=$duration_clock"
    failures=$((failures + 1))
  fi

  if [[ -n "$source_app" ]]; then
    if grep -Fq -- "- **App:** $source_app" "$export_path"; then
      write_check_line "$out" PASS "export source app matches latest session" "source_app=$source_app"
    else
      write_check_line "$out" FAIL "export source app matches latest session" "expected_source_app=$source_app"
      failures=$((failures + 1))
    fi
  else
    write_check_line "$out" WARN "export source app matches latest session" "source_app empty; manual start may be intentional"
    warnings=$((warnings + 1))
  fi

  if grep -Fxq "## Transcript" "$export_path"; then
    write_check_line "$out" PASS "export has transcript section" "heading_present=yes"
  else
    write_check_line "$out" FAIL "export has transcript section" "heading_present=no"
    failures=$((failures + 1))
  fi

  if is_int "$segments" && is_int "$transcript_lines" && (( transcript_lines == segments )); then
    write_check_line "$out" PASS "export transcript row count matches latest session" "export_rows=$transcript_lines session_segments=$segments"
  else
    write_check_line "$out" FAIL "export transcript row count matches latest session" "export_rows=${transcript_lines:-unknown} session_segments=${segments:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$export_speakers" && (( export_speakers >= 2 )); then
    write_check_line "$out" PASS "export contains multiple speaker labels" "export_speakers=$export_speakers"
  else
    write_check_line "$out" FAIL "export contains multiple speaker labels" "export_speakers=${export_speakers:-unknown}"
    failures=$((failures + 1))
  fi

  if is_int "$notes_chars" && (( notes_chars > 0 )); then
    if grep -Fxq "## Key Notes" "$export_path"; then
      write_check_line "$out" PASS "export has notes section" "session_notes_chars=$notes_chars"
    else
      write_check_line "$out" FAIL "export has notes section" "session_notes_chars=$notes_chars"
      failures=$((failures + 1))
    fi
  else
    write_check_line "$out" WARN "export has notes section" "latest session has no notes to export"
    warnings=$((warnings + 1))
  fi

  printf 'failures=%s warnings=%s\n' "$failures" "$warnings" >> "$out"
  return "$failures"
}

write_preflight() {
  local dir="$1"
  {
    printf 'Gate 2 real-meeting proof preflight\n'
    printf 'Generated: %s\n' "$(date)"
    printf 'Repo: %s\n' "$root_dir"
    printf 'Branch: '
    git -C "$root_dir" branch --show-current 2>/dev/null || true
    printf 'HEAD: '
    git -C "$root_dir" rev-parse HEAD 2>/dev/null || true
    printf '\nmacOS:\n'
    sw_vers
    printf '\nXcode:\n'
    xcodebuild -version
    printf '\nXcodeGen:\n'
    xcodegen --version 2>/dev/null || printf 'xcodegen unavailable\n'
    printf '\nDebug defaults:\n'
    bool_default debugAutoStart
    bool_default debugAudioDump
    bool_default debugDiag
    printf '\nOpenAI API key presence:\n'
    if security find-generic-password -s "$keychain_service" -a "$keychain_account" >/dev/null 2>&1; then
      printf 'present (value not read)\n'
    else
      printf 'absent or unreadable\n'
    fi
    printf '\nApp artifact:\n'
    if [[ -d "$app_path" ]]; then
      printf 'present: %s\n' "$app_path"
    else
      printf 'missing: %s\n' "$app_path"
      printf 'Build it with: xcodebuild -scheme Transcriber -configuration Debug -derivedDataPath build build\n'
    fi
  } > "$dir/preflight.txt"

  write_tcc_status "$dir/tcc-status.txt"
  write_latest_session "$dir/latest-session-before.txt"
  latest_session_pk > "$dir/latest-session-before.pk"
}

reset_debug_defaults() {
  defaults write "$bundle_id" debugAutoStart -bool false
  defaults write "$bundle_id" debugAudioDump -bool false
}

start_run() {
  local dir
  dir="$(new_run_dir)"
  reset_debug_defaults
  defaults write "$bundle_id" debugDiag -bool true
  write_preflight "$dir"

  if [[ ! -d "$app_path" ]]; then
    printf 'Missing app artifact: %s\n' "$app_path" >&2
    printf 'Run xcodegen generate and xcodebuild before starting the proof.\n' >&2
    exit 1
  fi

  /usr/bin/open -n "$app_path"
  sleep 3
  pgrep -fl '/Transcriber.app/Contents/MacOS/Transcriber' > "$dir/app-process-start.txt" || true

  printf 'Gate 2 proof run directory: %s\n' "$dir"
  printf 'Next: run the real Google Meet/Zoom scenario, stop the app session, then run:\n'
  printf '  scripts/gate2-real-meeting-proof.sh summarize\n'
}

summarize_run() {
  local dir
  dir="$(current_run_dir)"
  write_latest_session "$dir/latest-session-after.txt"
  latest_session_pk > "$dir/latest-session-after.pk"
  local before_pk after_pk check_status=0
  before_pk="$(cat "$dir/latest-session-before.pk" 2>/dev/null || printf 'unknown')"
  after_pk="$(cat "$dir/latest-session-after.pk" 2>/dev/null || printf 'unknown')"
  write_gate2_checks "$dir/gate2-checks.txt" "$before_pk" "$after_pk" || check_status=$?
  {
    printf 'Gate 2 proof summary\n'
    printf 'Generated: %s\n' "$(date)"
    printf 'Run directory: %s\n' "$dir"
    printf 'Before latest session pk: %s\n' "$before_pk"
    printf 'After latest session pk: %s\n' "$after_pk"
    printf '\nGate 2 required checks:\n\n'
    cat "$dir/gate2-checks.txt"
    printf '\nExport verification:\n\n'
    if [[ -f "$dir/export-checks.txt" ]]; then
      cat "$dir/export-checks.txt"
    else
      printf 'No export verification recorded yet. After saving Markdown from the app, run:\n'
      printf '  scripts/gate2-real-meeting-proof.sh verify-export /path/to/export.md\n'
    fi
    printf '\nLatest session metadata follows; transcript text and title text are intentionally omitted.\n\n'
    cat "$dir/latest-session-after.txt"
  } > "$dir/summary.txt"
  cat "$dir/summary.txt"
  return "$check_status"
}

verify_export() {
  local export_path="${1:-}"
  if [[ -z "$export_path" ]]; then
    printf 'Missing export path.\n' >&2
    usage >&2
    exit 2
  fi

  local dir check_status=0
  dir="$(current_run_dir)"
  write_export_checks "$export_path" "$dir/export-checks.txt" || check_status=$?
  {
    printf 'Gate 2 export verification\n'
    printf 'Generated: %s\n' "$(date)"
    printf 'Run directory: %s\n' "$dir"
    printf 'Export path: %s\n\n' "$export_path"
    cat "$dir/export-checks.txt"
    printf '\nTranscript text and notes text were inspected only for structure/counts and were not printed or copied.\n'
  } > "$dir/export-summary.txt"
  cat "$dir/export-summary.txt"
  return "$check_status"
}

cmd="${1:-}"
case "$cmd" in
  preflight)
    dir="$(new_run_dir)"
    write_preflight "$dir"
    printf 'Wrote preflight evidence to %s\n' "$dir"
    ;;
  start)
    start_run
    ;;
  summarize)
    summarize_run
    ;;
  verify-export)
    verify_export "${2:-}"
    ;;
  reset-debug-defaults)
    reset_debug_defaults
    printf 'debugAutoStart=0 and debugAudioDump=0\n'
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
