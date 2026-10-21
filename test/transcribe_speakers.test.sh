#!/bin/bash
# A take with system audio carries a stereo "speakers" track: microphone left,
# what the Mac played right. Transcribing it must ask whisper to diarize that
# track and turn its speaker tags into names, so the person who recorded is
# never credited with the other side's words, or the other way round. A take
# without the track, older or microphone-only, must be transcribed as before.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/transcribe-sandbox.sh
. "$ROOT/test/lib/transcribe-sandbox.sh"

BASE=$(sandbox_base speakers)
trap 'rm -rf "$BASE"' EXIT
DIR="$BASE/Recordings"
VAULT="$BASE/Documents/Notebook"
NOTES="$VAULT/Recordings"
BIN="$BASE/bin"
TMP="$BASE/tmp"
ARGV="$BASE/argv"
for path in "$DIR" "$VAULT" "$NOTES" "$BIN" "$TMP" "$ARGV"; do
  sandbox_guard "$path" "$BASE" "test fixture"
done
mkdir -p "$DIR" "$VAULT/.obsidian" "$NOTES" "$BIN" "$TMP"
seed_recordings "$DIR"
make_stubs "$BIN"

# 09-00 has the speakers track, 10-00 does not.
cat > "$BIN/ffprobe" <<'EOF2'
#!/bin/bash
set -euo pipefail
if printf '%s\n' "$@" | grep -qx 'stream_tags=handler_name'; then
  case "${!#}" in
    *09-00.mp4) echo speakers ;;
    *) echo SoundHandler ;;
  esac
  exit 0
fi
echo 30.000000
EOF2
# Every call logs its arguments; a diarized call answers with speaker tags.
cat > "$BIN/whisper-cli" <<'EOF2'
#!/bin/bash
set -euo pipefail
{ echo ---; printf '%s\n' "$@"; } >> "$RECORD_TEST_ARGV"
if printf '%s\n' "$@" | grep -qx -- '--diarize'; then
  echo '[00:00:00.000 --> 00:00:04.000]  (speaker 0) Can you tell me how the search ranking works for the catalog?'
  echo '[00:00:04.000 --> 00:00:09.000]  (speaker 1) The ranking uses popularity and stock and boosts private label items.'
  echo '[00:00:09.000 --> 00:00:11.000]  (speaker ?) Right, right, okay then.'
else
  echo '[00:00:00.000 --> 00:00:04.000]  An older take recorded before the speakers track existed at all.'
fi
EOF2
# ffmpeg logs too, so the channel count of each extraction can be read back.
cat > "$BIN/ffmpeg" <<'EOF2'
#!/bin/bash
set -euo pipefail
{ echo --- ffmpeg; printf '%s\n' "$@"; } >> "$RECORD_TEST_ARGV"
out="${!#}"
case "$out" in *.wav) : > "$out" ;; esac
EOF2
chmod +x "$BIN/ffprobe" "$BIN/whisper-cli" "$BIN/ffmpeg"

fail=0
bad() { echo "FAIL: $1"; fail=1; }

out=$(run_transcribe "$ROOT" "$BASE" "$BIN" "$TMP" "$DIR" "$VAULT" "$NOTES" \
  RECORD_AI=0 RECORD_TEST_ARGV="$ARGV" 'RECORD_SPEAKER_ME=Ludo & co' RECORD_SPEAKER_OTHERS=Omid)
note=$(find "$NOTES" -maxdepth 1 -name '*.md' -print)
[ -n "$note" ] || { echo "FAIL: no note: $out"; exit 1; }

grep -qF '[00:00:00.000 --> 00:00:04.000]  Ludo & co: Can you tell me' "$note" \
  || bad "the microphone side is not labelled with RECORD_SPEAKER_ME"
grep -qF '[00:00:04.000 --> 00:00:09.000]  Omid: The ranking uses' "$note" \
  || bad "the system audio side is not labelled with RECORD_SPEAKER_OTHERS"
grep -qF '[00:00:09.000 --> 00:00:11.000]  Ludo & co/Omid: Right' "$note" \
  || bad "an undecided segment is not labelled as both"
grep -q '(speaker' "$note" && bad "a raw whisper speaker tag reached the note"
grep -qF 'An older take recorded before the speakers track' "$note" \
  || bad "the take without a speakers track was not transcribed"
grep -qF 'Ludo & co: the microphone on this Mac' "$note" \
  || bad "the note does not say what the labels mean"

# The speakers take is extracted in stereo from audio track 1 and diarized;
# the other is extracted in mono from the default track and is not.
grep -A2 -x -- '-map' "$ARGV" | grep -qx '0:a:1' || bad "the speakers track was not picked"
[ "$(grep -A1 -x -- '-ac' "$ARGV" | grep -cx 2)" -ge 1 ] || bad "no stereo extraction"
[ "$(grep -A1 -x -- '-ac' "$ARGV" | grep -cx 1)" -ge 1 ] || bad "the older take lost its mono extraction"
[ "$(grep -cx -- '--diarize' "$ARGV")" -ge 1 ] || bad "whisper was never asked to diarize"
calls=$(grep -c '^---$' "$ARGV")
[ "$(grep -cx -- '--diarize' "$ARGV")" -lt "$calls" ] || bad "the older take was diarized too"

[ "$fail" = 0 ] || { echo "$out"; exit 1; }
echo "transcribe_speakers: ok"
