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
# HDR
#
# These sources are HDR, and NVENC does not carry HDR metadata through an
# encode. Two halves to that:
#
#   The colour tags (bt2020 / smpte2084 / bt2020nc) and 10-bit depth are
#   set explicitly on the encode. Without them the output is tagged SDR
#   and plays washed-out grey on an HDR display.
#
#   The mastering-display and content-light-level values cannot be passed
#   to hevc_nvenc at all -- it takes no master_display or max_cll option.
#   They are read off the source and written back into the MKV container
#   afterwards with mkvpropedit, which players read in preference to the
#   stream's own SEI.
#
# What is genuinely lost: Dolby Vision RPU and HDR10+ dynamic metadata.
# Preserving those means demuxing the RPU with dovi_tool and re-injecting
# it, which NVENC output cannot take. The result falls back to base HDR10
# -- correct, just static rather than per-scene.
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

# --- read HDR static metadata off the source -------------------------------
# Captured before the encode because the encode destroys it. Applied again
# after, via mkvpropedit. A non-HDR source yields nothing here and the
# whole block no-ops.
# Two probes: the colour tags live on the stream, but the mastering-display
# and light-level blocks are frame side data. `-show_entries side_data`
# alone puts ffprobe into packets_and_frames mode and walks all 69 GB, so
# the frame probe is pinned to the first frame with -read_intervals.
hdr_stream=$(probe -select_streams v:0 -show_entries stream=color_primaries,color_transfer,color_space \
               -of json "/w/$BASE")
hdr_frame=$(probe -select_streams v:0 -read_intervals '%+#1' -show_frames \
               -show_entries frame=side_data_list -of json "/w/$BASE")
hdr_json=$(printf '%s\n%s' "$hdr_stream" "$hdr_frame")

eval "$(printf '%s' "$hdr_json" | python3 -c "
import sys, json
from fractions import Fraction

def num(v):
    try: return float(Fraction(str(v)))
    except Exception: return None

# two JSON documents back to back: the stream probe then the frame probe
dec = json.JSONDecoder()
text = sys.stdin.read()
docs, i = [], 0
while i < len(text):
    while i < len(text) and text[i].isspace(): i += 1
    if i >= len(text): break
    obj, i = dec.raw_decode(text, i)
    docs.append(obj)

st, side = {}, []
for d in docs:
    if d.get('streams'): st = d['streams'][0]
    if d.get('frames'):  side = d['frames'][0].get('side_data_list', [])

out = {}
for k in ('color_primaries', 'color_transfer', 'color_space'):
    if st.get(k) not in (None, 'unknown'):
        out[k.upper()] = st[k]

for sd in side:
    t = sd.get('side_data_type', '')
    if t == 'Mastering display metadata':
        for tag, key in (('red_x','MD_RX'),('red_y','MD_RY'),
                         ('green_x','MD_GX'),('green_y','MD_GY'),
                         ('blue_x','MD_BX'),('blue_y','MD_BY'),
                         ('white_point_x','MD_WX'),('white_point_y','MD_WY'),
                         ('min_luminance','MD_MINL'),('max_luminance','MD_MAXL')):
            v = num(sd.get(tag))
            if v is not None: out[key] = repr(v)
    elif t == 'Content light level metadata':
        if sd.get('max_content') is not None: out['CLL_MAX']  = str(sd['max_content'])
        if sd.get('max_average') is not None: out['CLL_FALL'] = str(sd['max_average'])

for k, v in out.items():
    print(f\"{k}='{v}'\")
")"

if [ -n "${COLOR_TRANSFER:-}" ]; then
  echo "    HDR: $COLOR_PRIMARIES / $COLOR_TRANSFER / $COLOR_SPACE${MD_MAXL:+, mastering display ${MD_MAXL} nits}${CLL_MAX:+, MaxCLL ${CLL_MAX}}"
  # Tags only, no -pix_fmt. With -hwaccel_output_format cuda the decoder
  # already hands NVENC 10-bit P010 surfaces in device memory; forcing a
  # pixel format makes ffmpeg insert a scale filter it cannot build, and
  # the encode dies with "Impossible to convert between the formats
  # supported by the filter". Bit depth is inherited from the source.
  COLOR_ARGS=(-color_primaries "$COLOR_PRIMARIES"
              -color_trc "$COLOR_TRANSFER"
              -colorspace "$COLOR_SPACE")
else
  COLOR_ARGS=()
fi

# --- pick subtitles ---------------------------------------------------------
# English text subtitles only, enumerated explicitly rather than with a
# `0:s:m:language:eng?` map: ffmpeg 9 rejects the optional-suffix form, and
# listing the streams also lets PGS be excluded. PGS is a bitmap format --
# copying every language of it is how a file ends up with 70 subtitle
# tracks and most of a gigabyte of subtitles.
sub_json=$(probe -select_streams s -show_entries stream=index,codec_name:stream_tags=language \
             -of json "/w/$BASE")
mapfile -t SUB_MAPS < <(printf '%s' "$sub_json" | python3 -c "
import sys, json
TEXT = {'subrip', 'ass', 'ssa', 'mov_text', 'webvtt', 'text'}
for st in json.load(sys.stdin).get('streams', []):
    lang = (st.get('tags') or {}).get('language', '').lower()
    if st.get('codec_name') in TEXT and lang in ('eng', 'en', ''):
        print('-map'); print('0:%d' % st['index'])
")
echo "    subtitles: $(( ${#SUB_MAPS[@]} / 2 )) English text track(s) kept"
echo "==> encoding (cq $CQ${SCALE:+, scaled to 1080p})"
VF=(); [ -n "$SCALE" ] && VF=(-vf "$SCALE")

start=$(date +%s)
run ffmpeg -hide_banner -loglevel warning -stats \
  -hwaccel cuda -hwaccel_output_format cuda \
  -i "/w/$BASE" \
  -map 0:v:0 -map "0:$A_IDX" "${SUB_MAPS[@]}" \
  "${VF[@]}" \
  -c:v hevc_nvenc -preset p6 -tune hq -rc vbr -cq "$CQ" -b:v 0 -spatial-aq 1 \
  "${COLOR_ARGS[@]}" \
  "${AUDIO_ARGS[@]}" \
  -c:s copy \
  -map_metadata 0 -metadata title= -metadata comment= \
  -y "/w/$(basename "$OUT")"
rc=$?
elapsed=$(( $(date +%s) - start ))

[ "$rc" -eq 0 ] && [ -s "$OUT" ] || { echo "    ffmpeg failed (rc=$rc)" >&2; rm -f "$OUT"; exit 1; }

# --- put the HDR mastering metadata back -----------------------------------
# hevc_nvenc has no option for these, so they go into the MKV container.
if [ -n "${MD_MAXL:-}" ] && command -v mkvpropedit >/dev/null 2>&1; then
  mkvpropedit "$OUT" --edit track:v1 \
    --set chromaticity-coordinates-red-x="$MD_RX"   --set chromaticity-coordinates-red-y="$MD_RY" \
    --set chromaticity-coordinates-green-x="$MD_GX" --set chromaticity-coordinates-green-y="$MD_GY" \
    --set chromaticity-coordinates-blue-x="$MD_BX"  --set chromaticity-coordinates-blue-y="$MD_BY" \
    --set white-coordinates-x="$MD_WX"              --set white-coordinates-y="$MD_WY" \
    --set max-luminance="$MD_MAXL"                  --set min-luminance="$MD_MINL" \
    ${CLL_MAX:+--set max-content-light="$CLL_MAX"} \
    ${CLL_FALL:+--set max-frame-light="$CLL_FALL"} >/dev/null \
    && echo "    HDR mastering metadata restored" \
    || echo "    WARNING: mkvpropedit failed; output is missing HDR mastering data" >&2
fi

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
