#!/usr/bin/env bash
# Re-encode an oversized video to a streaming-sized HEVC file using the
# GPU, keeping one audio track and text subtitles.
#
#   scripts/transcode.sh <file> [--cq 28] [--1080p] [--replace]
#
# WHY THIS EXISTS
#
# UHD Blu-ray remuxes are enormous and almost all of it is video. Measured
# on a 109-minute 2160p remux in this library:
#
#   video (HEVC, 78 Mbps)   64.08 GB
#   TrueHD 7.1               3.40 GB
#   AC3 5.1                  0.52 GB
#   ~70 subtitle tracks       0.7 GB
#                            -------
#                           69 GB total
#
# Dropping the lossless audio saves 3.4 GB. Only re-encoding the video
# matters. At cq 28 the same file came out around 5.5 Mbps, roughly 4.7 GB,
# encoding at 1.82x realtime -- about an hour for a two-hour film.
#
# WHY NVENC AND NOT x265
#
# CPU x265 gives better quality per bit, but this host is a 6-core Xeon
# E5-1650 v3. At 2160p it manages low single-digit fps, so a feature film
# is a 20-hour job. NVENC on the RTX 2080 SUPER does the same work in an
# hour. For shrinking remuxes that is the right trade; for archival masters
# it would not be.
#
# THE GPU IS SHARED. Plex transcodes on this card and Ollama loads models
# onto it. A long encode will compete with both, and Turing limits
# concurrent NVENC sessions. Run this when you are not streaming.
set -uo pipefail

CQ=28
SCALE=""
REPLACE=0
IN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cq) CQ="$2"; shift 2 ;;
    --1080p) SCALE="scale_cuda=1920:-2"; shift ;;
    --replace) REPLACE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) IN="$1"; shift ;;
  esac
done

[ -n "$IN" ] && [ -f "$IN" ] || { echo "usage: $0 <file> [--cq N] [--1080p] [--replace]" >&2; exit 1; }

IMG=linuxserver/ffmpeg:latest
DIR=$(cd "$(dirname "$IN")" && pwd)
BASE=$(basename "$IN")
STEM="${BASE%.*}"
OUT="$DIR/${STEM}.__transcode__.mkv"

run() { docker run --rm --device nvidia.com/gpu=all -v "$DIR":/w --entrypoint "$1" "$IMG" "${@:2}"; }

probe() { run ffprobe -v error "$@"; }

echo "==> source"
src_dur=$(probe -show_entries format=duration -of csv=p=0 "/w/$BASE")
src_size=$(stat -c %s "$IN")
printf '    %s\n    %.1f GB, %.0f min\n' "$BASE" "$(echo "$src_size/1000000000" | bc -l)" "$(echo "$src_dur/60" | bc -l)"

# --- pick ONE audio track -------------------------------------------------
# Highest channel count wins. A lossless track (TrueHD, DTS-HD) is
# re-encoded to E-AC3 rather than copied: keeping it would leave several GB
# of audio on a file whose whole point is being small.
audio_json=$(probe -select_streams a -show_entries stream=index,codec_name,channels -of json "/w/$BASE")
read -r A_IDX A_CODEC A_CH <<<"$(printf '%s' "$audio_json" | python3 -c "
import sys, json
st = json.load(sys.stdin).get('streams', [])
if not st: print('- - -'); raise SystemExit
best = max(st, key=lambda s: int(s.get('channels') or 0))
print(best['index'], best.get('codec_name','?'), best.get('channels','?'))
")"
[ "$A_IDX" = "-" ] && { echo "    no audio stream found" >&2; exit 1; }

case "$A_CODEC" in
  truehd|dts|mlp|flac|pcm*) AUDIO_ARGS=(-c:a eac3 -b:a 640k -ac 6); AMODE="re-encode to E-AC3 640k" ;;
  *)                        AUDIO_ARGS=(-c:a copy);                 AMODE="copy" ;;
esac
echo "    audio: stream $A_IDX $A_CODEC ${A_CH}ch -> $AMODE"

# Text subtitles only. PGS is a bitmap format; it cannot be re-encoded here
# and copying every language is how a file ends up with 70 subtitle tracks.
echo "==> encoding (cq $CQ${SCALE:+, scaled to 1080p})"
VF=(); [ -n "$SCALE" ] && VF=(-vf "$SCALE")

start=$(date +%s)
run ffmpeg -hide_banner -loglevel warning -stats \
  -hwaccel cuda -hwaccel_output_format cuda \
  -i "/w/$BASE" \
  -map 0:v:0 -map "0:$A_IDX" -map "0:s:m:language:eng?" \
  "${VF[@]}" \
  -c:v hevc_nvenc -preset p6 -tune hq -rc vbr -cq "$CQ" -b:v 0 -spatial_aq 1 \
  "${AUDIO_ARGS[@]}" \
  -c:s copy \
  -map_metadata 0 -metadata title= -metadata comment= \
  -y "/w/$(basename "$OUT")"
rc=$?
elapsed=$(( $(date +%s) - start ))

[ "$rc" -eq 0 ] && [ -s "$OUT" ] || { echo "    ffmpeg failed (rc=$rc)" >&2; rm -f "$OUT"; exit 1; }

# --- verify before anything replaces anything -----------------------------
out_dur=$(probe -show_entries format=duration -of csv=p=0 "/w/$(basename "$OUT")")
out_size=$(stat -c %s "$OUT")
ok=$(python3 -c "
try: print(1 if abs(float('$src_dur')-float('$out_dur')) < 2.0 else 0)
except Exception: print(0)")

printf '==> result\n    %.2f GB -> %.2f GB  (%.0f%% smaller) in %dm\n' \
  "$(echo "$src_size/1000000000"|bc -l)" "$(echo "$out_size/1000000000"|bc -l)" \
  "$(echo "(1-$out_size/$src_size)*100"|bc -l)" "$((elapsed/60))"
printf '    duration %.1fs -> %.1fs  %s\n' "$src_dur" "$out_dur" \
  "$([ "$ok" = 1 ] && echo 'match' || echo 'MISMATCH')"

if [ "$ok" != "1" ]; then
  echo "    duration differs by more than 2s; leaving both files in place" >&2
  exit 1
fi

if [ "$REPLACE" = "1" ]; then
  mv -f -- "$OUT" "$DIR/${STEM}.mkv"
  [ "$BASE" != "${STEM}.mkv" ] && rm -f -- "$IN"
  echo "    replaced the original"
else
  echo "    kept as $(basename "$OUT")  (pass --replace to swap it in)"
fi
