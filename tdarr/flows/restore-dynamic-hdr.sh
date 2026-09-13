#!/usr/bin/env bash
# Put Dolby Vision and HDR10+ back onto an NVENC re-encode.
#
#   restore-dynamic-hdr.sh <source> <encoded.mkv> <out.mkv>
#
# Called by the Tdarr shrink flow after the encode (tdarr/flows/, mounted
# at /opt/shrink). The same recipe as scripts/transcode.sh, which runs it
# on the host; see that file for the long version of why.
#
# NVENC keeps static HDR10 (colour tags, mastering display, MaxCLL) but
# drops the dynamic layers. Both ride in SEI units between slices, so they
# can be lifted off the source and injected into the new stream without
# another encode, then the video is remuxed with everything else.
#
# Exit codes, which the flow reads:
#   0  <out.mkv> written with DV and/or HDR10+ restored
#   3  nothing to restore (not PQ HDR, or no dynamic metadata); use encoded
#   1  restore was needed but failed; <out.mkv> not written, the encode is
#      still valid static HDR10
set -uo pipefail
export PATH="/opt/hdr-tools:$PATH"

src=$1 enc=$2 out=$3
probe() { ffprobe -v error "$@"; }

trc=$(probe -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$src" | head -1)
[ "$trc" = smpte2084 ] || { echo "source is not PQ HDR ($trc)"; exit 3; }

# What the source carries. DV config is stream side data; HDR10+ is only
# visible per frame, so the first frame is probed (not the whole file).
dv_profile=$(probe -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 "$src" | head -1)
has_hp=0
probe -select_streams v:0 -read_intervals '%+#1' -show_frames -show_entries frame_side_data=side_data_type \
  -of default=nw=1:nk=1 "$src" | grep -q 'SMPTE2094-40' && has_hp=1
[ -n "$dv_profile" ] || [ "$has_hp" = 1 ] || { echo "no Dolby Vision or HDR10+ in source"; exit 3; }

work=$(mktemp -d "$(dirname "$out")/.dynhdr.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { echo "restore failed: $*"; exit 1; }

# One read of the source feeding whichever extractors apply. `tee -p`
# keeps feeding the other one if either exits early.
sinks=() pids=()
if [ -n "$dv_profile" ]; then
  mkfifo "$work/dv"
  dovi_tool --mode 2 extract-rpu - -o "$work/rpu.bin" <"$work/dv" >/dev/null 2>&1 &
  pids+=($!) sinks+=("$work/dv")
fi
if [ "$has_hp" = 1 ]; then
  mkfifo "$work/hp"
  hdr10plus_tool extract - -o "$work/hp.json" <"$work/hp" >/dev/null 2>&1 &
  pids+=($!) sinks+=("$work/hp")
fi
ffmpeg -hide_banner -loglevel error -i "$src" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - \
  | tee -p "${sinks[@]}" >/dev/null
for p in "${pids[@]}"; do wait "$p"; done

have_dv=0 have_hp=0
[ -s "$work/rpu.bin" ] && have_dv=1
[ -s "$work/hp.json" ] && have_hp=1
[ "$have_dv" = 1 ] || [ "$have_hp" = 1 ] || fail "extractors produced nothing"

# Injection pairs metadata with frames by position, so counts must match.
enc_frames=$(probe -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$enc" | tr -d ',\r')
if [ "$have_dv" = 1 ]; then
  n=$(dovi_tool info -i "$work/rpu.bin" -s 2>/dev/null | grep -oE 'Frames: [0-9]+' | grep -oE '[0-9]+')
  [ "$n" = "$enc_frames" ] || fail "RPU has $n frames, encode has $enc_frames"
  el=$(dovi_tool info -i "$work/rpu.bin" -s 2>/dev/null | grep -oE 'Profile: [0-9]+ \((MEL|FEL)\)' || true)
fi
if [ "$have_hp" = 1 ]; then
  n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('SceneInfo', [])))" "$work/hp.json" 2>/dev/null \
      || grep -o '"SceneFrameIndex"' "$work/hp.json" | wc -l)
  [ "$n" = "$enc_frames" ] || fail "HDR10+ has $n frames, encode has $enc_frames"
fi

ffmpeg -hide_banner -loglevel error -i "$enc" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc -y "$work/bl.hevc" \
  || fail "could not extract encoded stream"
cur="$work/bl.hevc"
if [ "$have_hp" = 1 ]; then
  hdr10plus_tool inject -i "$cur" -j "$work/hp.json" -o "$work/v1.hevc" >/dev/null 2>&1 && [ -s "$work/v1.hevc" ] \
    || fail "HDR10+ injection"
  rm -f -- "$cur"; cur="$work/v1.hevc"
fi
if [ "$have_dv" = 1 ]; then
  dovi_tool inject-rpu -i "$cur" --rpu-in "$work/rpu.bin" -o "$work/v2.hevc" >/dev/null 2>&1 && [ -s "$work/v2.hevc" ] \
    || fail "RPU injection"
  rm -f -- "$cur"; cur="$work/v2.hevc"
fi

# Raw HEVC has no container timestamps, so the source frame rate is given
# explicitly rather than trusting VUI timing. Everything but the video
# comes from the encode.
fps=$(probe -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$src" | head -1)
mkvmerge -q -o "$work/out.mkv" --default-duration "0:${fps}fps" "$cur" --no-video "$enc" >/dev/null 2>&1 \
  || fail "mkvmerge remux"

# The remux rebuilt the container; restore static HDR10 on the track so
# players that read container colour rather than SEI still see it.
eval "$(probe -select_streams v:0 -read_intervals '%+#1' -show_frames -show_entries frame_side_data -of json "$src" \
  | python3 -c '
import json, sys
from fractions import Fraction
num = lambda v: float(Fraction(str(v)))
out = {}
for sd in json.load(sys.stdin)["frames"][0].get("side_data_list", []):
    t = sd.get("side_data_type", "")
    if t == "Mastering display metadata":
        for k in ("red_x","red_y","green_x","green_y","blue_x","blue_y","white_point_x","white_point_y","min_luminance","max_luminance"):
            out["MD_" + k.upper()] = repr(num(sd[k]))
    elif t == "Content light level metadata":
        out["CLL_MAX"], out["CLL_FALL"] = sd["max_content"], sd["max_average"]
for k, v in out.items():
    print(f"{k}={v}")
')"
props=(--set colour-primaries=9 --set colour-transfer-characteristics=16 --set colour-matrix-coefficients=9)
if [ -n "${MD_MAX_LUMINANCE:-}" ]; then
  props+=(--set chromaticity-coordinates-red-x="$MD_RED_X" --set chromaticity-coordinates-red-y="$MD_RED_Y"
          --set chromaticity-coordinates-green-x="$MD_GREEN_X" --set chromaticity-coordinates-green-y="$MD_GREEN_Y"
          --set chromaticity-coordinates-blue-x="$MD_BLUE_X" --set chromaticity-coordinates-blue-y="$MD_BLUE_Y"
          --set white-coordinates-x="$MD_WHITE_POINT_X" --set white-coordinates-y="$MD_WHITE_POINT_Y"
          --set max-luminance="$MD_MAX_LUMINANCE" --set min-luminance="$MD_MIN_LUMINANCE")
fi
[ -n "${CLL_MAX:-}" ] && props+=(--set max-content-light="$CLL_MAX" --set max-frame-light="$CLL_FALL")
mkvpropedit -q "$work/out.mkv" --edit track:v1 "${props[@]}" >/dev/null 2>&1 || fail "mkvpropedit"

# Verify the result carries what was injected before handing it back.
got_dv=$(probe -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 "$work/out.mkv" | head -1)
[ "$have_dv" = 0 ] || [ -n "$got_dv" ] || fail "output has no DV configuration record"

mv -f -- "$work/out.mkv" "$out"
echo "restored:$([ "$have_dv" = 1 ] && echo " Dolby Vision ${dv_profile} -> ${got_dv:-?} ${el:-}")$([ "$have_hp" = 1 ] && echo " HDR10+") over $enc_frames frames"
exit 0
