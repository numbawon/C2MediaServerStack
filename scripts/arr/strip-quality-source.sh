#!/usr/bin/env bash
# Rewrites "[Bluray-1080p]" to "[1080p]" in the names Radarr and Sonarr
# produce, so the library reads `Title (Year) [1080p]` instead of carrying
# the source in the bracket.
#
# WHY THIS EXISTS
#
# Neither app has a bare-resolution naming token. Checked directly against
# both frontends: the complete set is {Quality Title}, {Quality Full} and
# the {MediaInfo *} family, and none render a plain "1080p".
#
# The native workaround does not work either. Radarr's quality *titles*
# are editable and {Quality Title} renders the title, so renaming them all
# to "1080p" would have needed no script at all -- but titles must be
# unique. Setting HDTV-1080p to "1080p" is accepted; setting WEBDL-1080p
# to the same thing is silently refused and the old title stays. Only one
# quality per resolution can carry the name, so the approach collapses.
#
# Hence: let the app name the file (it handles titles, colons, illegal
# characters and year formatting correctly), then strip the source prefix
# out of the bracket afterwards and tell the app where the file went.
#
# HOW IT IS WIRED
#
# Settings -> Connect -> Custom Script, on the Import/Upgrade event. The
# app runs it inside its own container with the relevant *_ env vars set.
#
# WHY IT IS ALSO ON THE RENAME TRIGGER
#
# The app's naming format still says [{Quality Title}], so a manual
# "Rename Files" would put the source straight back. Wiring this to
# onRename as well as onDownload/onUpgrade means the app immediately
# undoes its own work, so the two settings stop fighting. Without that,
# every rename would need a manual sweep afterwards:
#
#     docker exec radarr /scripts/strip-quality-source.sh --all
#     docker exec sonarr /scripts/strip-quality-source.sh --all
#
# which still works, and is the way to fix the existing library.
set -uo pipefail

LOG_TAG="strip-quality-source"
# Logs go to stdout, and rename_if_needed returns its result in the global
# RENAMED_PATH rather than by echoing it. The obvious alternative -- echo
# the path, capture stdout -- means callers write >/dev/null and silently
# swallow every log line from inside the function, so real renames leave
# no trace. Routing logs to stderr instead fixes the visibility but the
# apps classify anything on stderr as an Error, which makes ordinary
# operation look like failure in their logs. A global is uglier and
# correct.
log() { echo "[$LOG_TAG] $*"; }

# Only rewrite a bracket that is exactly <word>-<digits>p. That is narrow
# on purpose:
#   [Bluray-1080p] -> [1080p]      wanted
#   [WEBDL-2160p]  -> [2160p]      wanted
#   [BR-DISK]      -> untouched    no resolution to keep
#   [SDTV]         -> untouched    no source to strip
#   [x265 DTS]     -> untouched    not a quality bracket at all
STRIP_RE='s/\[[A-Za-z]+-([0-9]+p)\]/[\1]/g'

# Extensions deleted from a media folder on import. Release groups ship
# spam beside the video -- www.YTS.MX.jpg, YTSProxies.com.txt,
# donate_to_help.txt, screenshot folders -- and a loose image is the one
# that does damage: Plex will use a jpg in a movie folder as the poster,
# which is how a torrent site logo becomes cover art.
#
# Plex is also configured with useLocalAssets=false, so it ignores these
# anyway. This is the second layer: nothing arrives, rather than arriving
# and being ignored. Posters are added deliberately through Plex later,
# never by whatever happened to be in a torrent.
#
# Subtitles are NOT in this list. srt/sub/idx are wanted.
JUNK_EXT="jpg jpeg png gif bmp nfo txt url sfv md5 srr exe lnk"

purge_junk() {  # $1 = directory
  local dir="$1" ext f
  [ -d "$dir" ] || return 0

  # Recursive, not just the top level. Release "Screens" and "Proof"
  # folders put their images one level down, and a shallow sweep leaves
  # exactly the artwork Plex is most likely to latch onto.
  local -a args=()
  for ext in $JUNK_EXT; do args+=( -iname "*.$ext" -o ); done
  unset 'args[${#args[@]}-1]'   # trailing -o

  find "$dir" -type f \( "${args[@]}" \) -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      rm -f -- "$f" && log "deleted junk: ${f#"$dir"/}"
    done

  # Then the now-empty directories they lived in. Only empties, so a
  # folder still holding anything real is never touched.
  find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null
}

strip_name() { printf '%s' "$1" | sed -E "$STRIP_RE"; }

# Rename a single path if its basename changes. Result lands in the
# global RENAMED_PATH (see the log() comment for why it is not echoed).
RENAMED_PATH=""
rename_if_needed() {
  local path="$1" dir base newbase newpath
  RENAMED_PATH="$path"
  dir=$(dirname "$path"); base=$(basename "$path")
  newbase=$(strip_name "$base")
  [ "$newbase" = "$base" ] && return 0
  newpath="$dir/$newbase"
  if [ -e "$newpath" ]; then
    log "target already exists, leaving alone: $newpath"
    return 0
  fi
  if mv -- "$path" "$newpath"; then
    log "renamed: $base -> $newbase"
    RENAMED_PATH="$newpath"
  else
    log "FAILED to rename: $path"
  fi
}

# --- app detection -------------------------------------------------------
# The env var prefix is the only reliable signal for which app invoked us.
if [ -n "${radarr_eventtype:-}" ] || [ "${1:-}" = "--radarr" ]; then
  APP=radarr; PORT=7878; API=v3
elif [ -n "${sonarr_eventtype:-}" ] || [ "${1:-}" = "--sonarr" ]; then
  APP=sonarr; PORT=8989; API=v3
elif [ -f /config/config.xml ]; then
  # --all invoked by hand: work out which app we are inside from the
  # config that is actually present.
  if grep -qi radarr /config/config.xml 2>/dev/null; then APP=radarr; PORT=7878; API=v3
  else APP=sonarr; PORT=8989; API=v3; fi
else
  log "cannot determine which app invoked this"; exit 1
fi

APIKEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)
[ -n "$APIKEY" ] || { log "no API key in /config/config.xml"; exit 1; }

# UrlBase must be honoured, not assumed empty. These instances have one
# set, so /api/v3/... answers 307 to /<urlbase>/api/v3/... and a PUT that
# follows the redirect arrives with its body dropped -- which fails as an
# opaque 400 rather than anything that names the cause.
URLBASE=$(sed -n 's:.*<UrlBase>\(.*\)</UrlBase>.*:\1:p' /config/config.xml)
URLBASE=${URLBASE#/}; URLBASE=${URLBASE%/}
if [ -n "$URLBASE" ]; then
  BASE="http://localhost:$PORT/$URLBASE/api/$API"
else
  BASE="http://localhost:$PORT/api/$API"
fi

api() { curl -fsSL -H "X-Api-Key: $APIKEY" "$@"; }

command_post() {  # $1 = json body
  api -X POST -H "Content-Type: application/json" -d "$1" "$BASE/command" >/dev/null \
    && log "queued: $1" || log "command failed: $1"
}

# --- event handling ------------------------------------------------------
EVENT="${radarr_eventtype:-${sonarr_eventtype:-}}"

# Connect's "Test" button fires with eventtype=Test and no paths. Succeed
# quietly so the test passes rather than reporting a broken script.
if [ "$EVENT" = "Test" ]; then log "test event, nothing to do"; exit 0; fi

if [ "${1:-}" = "--all" ]; then
  # Sweep the whole library. Deepest paths first so a directory is renamed
  # only after everything inside it has been.
  ROOTS=$(api "$BASE/rootfolder" | jq -r '.[].path')
  [ -n "$ROOTS" ] || { log "no root folders returned"; exit 1; }
  for root in $ROOTS; do
    log "sweeping $root"
    find "$root" -depth -name '*[[]*-*p]*' -print0 2>/dev/null |
      while IFS= read -r -d '' p; do rename_if_needed "$p"; done
  done
  # A full rescan is the only way to reconcile every path we just moved.
  if [ "$APP" = radarr ]; then command_post '{"name":"RescanMovie"}'
  else command_post '{"name":"RescanSeries"}'; fi
  log "sweep complete"
  exit 0
fi

# Events where a file exists and may have just been named by the app.
# Grab is excluded: it fires before anything is on disk. Rename is
# included precisely because that is when the app reinstates the source.
case "$EVENT" in
  Download|Upgrade|Rename) ;;
  *) log "ignoring event: ${EVENT:-<none>}"; exit 0 ;;
esac

if [ "$APP" = radarr ]; then
  FILE="${radarr_moviefile_path:-}"
  FOLDER="${radarr_movie_path:-}"
  MOVIE_ID="${radarr_movie_id:-}"
  # A Rename event names the movie, not an individual file, so there is
  # no moviefile_path to work from. The folder is enough: everything in
  # it was just renamed.
  if [ -z "$FILE" ] && [ -z "$FOLDER" ]; then
    log "neither file nor folder given"; exit 0
  fi

  # Every file in the folder, not just the video: Radarr renames sidecars
  # (subtitles, nfo) to match, and leaving those behind would split the
  # naming scheme across a single movie.
  if [ -d "$FOLDER" ]; then
    purge_junk "$FOLDER"
    for f in "$FOLDER"/*; do [ -f "$f" ] && rename_if_needed "$f"; done
  elif [ -n "$FILE" ]; then
    rename_if_needed "$FILE"
  fi

  # The folder itself carries the bracket too, and moving it means the
  # path stored in the database is stale. Update the record rather than
  # letting a rescan find an empty directory.
  if [ -n "$FOLDER" ] && [ -d "$FOLDER" ]; then
    rename_if_needed "$FOLDER"; NEWFOLDER="$RENAMED_PATH"
    if [ "$NEWFOLDER" != "$FOLDER" ] && [ -n "$MOVIE_ID" ]; then
      body=$(api "$BASE/movie/$MOVIE_ID" | jq --arg p "$NEWFOLDER" '.path = $p')
      api -X PUT -H "Content-Type: application/json" \
          -d "$body" "$BASE/movie/$MOVIE_ID?moveFiles=false" >/dev/null \
        && log "movie path updated to $NEWFOLDER" \
        || log "FAILED to update movie path"
    fi
  fi
  [ -n "$MOVIE_ID" ] && command_post "{\"name\":\"RescanMovie\",\"movieId\":$MOVIE_ID}"

else
  FILE="${sonarr_episodefile_path:-}"
  SERIES_ID="${sonarr_series_id:-}"
  SERIES_PATH="${sonarr_series_path:-}"

  # Same as Radarr: a Rename event gives the series, not a file. Walk the
  # whole series tree in that case.
  if [ -z "$FILE" ]; then
    if [ -n "$SERIES_PATH" ] && [ -d "$SERIES_PATH" ]; then
      find "$SERIES_PATH" -depth -type f -name '*[[]*-*p]*' -print0 2>/dev/null |
        while IFS= read -r -d '' f; do rename_if_needed "$f"; done
      [ -n "$SERIES_ID" ] && command_post "{\"name\":\"RescanSeries\",\"seriesId\":$SERIES_ID}"
    else
      log "no episode file and no series path"
    fi
    exit 0
  fi

  # Episodes only. The series folder is named from {Series Title} and
  # carries no quality, and season folders carry none either, so there is
  # nothing above the file to rewrite.
  DIR=$(dirname "$FILE")
  purge_junk "$DIR"
  for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      "$(basename "${FILE%.*}")"*) rename_if_needed "$f" ;;
    esac
  done
  [ -n "$SERIES_ID" ] && command_post "{\"name\":\"RescanSeries\",\"seriesId\":$SERIES_ID}"
fi

exit 0
