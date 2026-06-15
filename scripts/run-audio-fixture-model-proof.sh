#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$root_dir/work/model-fixture-proof"
stamp="$(date '+%Y%m%d-%H%M%S')"
run_dir="$work_root/run-$stamp"
fixture="$run_dir/speech-fixture.wav"
log_file="$run_dir/xcodebuild.log"
expected_word="quarterly"
marker_file="/tmp/transcriber-model-fixture-proof.env"
include_local_asr=0

usage() {
  cat <<'EOF'
Usage: scripts/run-audio-fixture-model-proof.sh [--include-local-asr]

Generates a temporary speech WAV and runs opt-in model fixture tests.

By default this runs the currently verified FluidAudio diarization fixture proof.
Use --include-local-asr to also run the local SpeechTranscriber fixture probe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-local-asr)
      include_local_asr=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$run_dir"
cleanup() {
  rm -f "$marker_file"
}
trap cleanup EXIT

cat > "$run_dir/fixture-text.txt" <<'EOF'
The quarterly planning meeting starts now.
The budget review follows after this sentence.
The local transcription fixture should capture these spoken words.
EOF

say \
  -v Samantha \
  -r 145 \
  -o "$fixture" \
  --file-format=WAVE \
  --data-format=LEF32@16000 \
  -f "$run_dir/fixture-text.txt"

{
  printf 'Audio fixture model proof\n'
  printf 'Run directory: %s\n' "$run_dir"
  printf 'Fixture: %s\n' "$fixture"
  printf 'Expected ASR word: %s\n' "$expected_word"
  printf 'Include local ASR fixture probe: %s\n' "$include_local_asr"
  printf 'Transcript text is not printed by this script.\n'
} > "$run_dir/summary.txt"

{
  printf 'TRANSCRIBER_RUN_FLUIDAUDIO_FIXTURE_TESTS=1\n'
  if [[ "$include_local_asr" == "1" ]]; then
    printf 'TRANSCRIBER_RUN_LOCAL_ASR_FIXTURE_TESTS=1\n'
  fi
  printf 'TRANSCRIBER_MODEL_FIXTURE_SPEECH_URL=%s\n' "$fixture"
  printf 'TRANSCRIBER_MODEL_FIXTURE_EXPECTED_WORD=%s\n' "$expected_word"
} > "$marker_file"

(
  cd "$root_dir"
  TRANSCRIBER_RUN_FLUIDAUDIO_FIXTURE_TESTS=1 \
  TRANSCRIBER_RUN_LOCAL_ASR_FIXTURE_TESTS="$include_local_asr" \
  TRANSCRIBER_MODEL_FIXTURE_SPEECH_URL="$fixture" \
  TRANSCRIBER_MODEL_FIXTURE_EXPECTED_WORD="$expected_word" \
  xcodebuild \
    -scheme Transcriber \
    -derivedDataPath build \
    test \
    -only-testing:TranscriberTests/ModelFixtureProofTests
) | tee "$log_file"

printf '\nProof artifacts written to %s\n' "$run_dir"
