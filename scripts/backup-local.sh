#!/usr/bin/env bash
# Fast local snapshot of every app's config volume. Does NOT back up media
# (/mnt/Media) -- too large, and it's not ephemeral state. Does NOT
# back up secret values either (Swarm secrets can't be exported by design) --
# that's what scripts/backup-offsite.sh + init-secrets.sh together cover:
# restic keeps an encrypted, restorable copy; a lost Swarm secret can also
# just be recreated with init-secrets.sh since most are random passwords
# apps rewrite state around, not user-chosen values.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Destination comes from .env so it moves with the storage layout rather
# than being hardcoded. An explicit argument still wins.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# Default deliberately lives on a DIFFERENT physical device from the
# volumes being snapshotted. Everything in VOLUMES below is a Docker named
# volume on the OS SSD, the media is on the array, and this lands on a
# third disk -- so no single failure takes both an original and its copy.
DEST="${1:-${COMMON_BACKUP_LOCAL:-/mnt/Storage/.backups/local}}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="$DEST/$STAMP"
mkdir -p "$OUT"

VOLUMES=(
  authentik_data pihole_config pihole_dnsmasq portainer_data postgres_data
  prometheus_data grafana_data sonarr_config radarr_config lidarr_config
  bazarr_config seerr_config lazylibrarian_config prowlarr_config
  tautulli_config navidrome_config organizarr_data
  # loki_data is deliberately NOT here. It holds nothing but logs:
  # chunks, their index, and a write-ahead log. loki-config.yaml lives
  # in this repo, so a restored Loki rebuilds itself and simply starts
  # empty.
  #
  # Logs are the instrument you triage WITH, not a record worth
  # keeping: their value is in the live context that produced them,
  # and it expires with that context. Restoring last month's access
  # logs tells you nothing useful about a host you have just rebuilt.
  # Retention is 30 days regardless, so the oldest of it was being
  # deleted anyway.
  #
  # It was also 7.8 GB, about 60% of the off-site backup and the
  # reason a run grew from 4.8 GiB to 13.0 GiB. Oversized snapshots
  # pushing past B2's cap is what silently broke this repo once
  # already -- see the exclusions note below.
  qbittorrent_config plex_config
  # ntfy_data holds every ntfy account and access token, including the
  # one configured in the phone's custom headers -- losing it means
  # re-issuing and re-entering them by hand.
  alertmanager_data ntfy_data diun_data
  # Stage 3. immich_db_data is the important one: it holds every photo's
  # metadata, albums, faces and search embeddings. The photo FILES live on
  # a media path and are not in here.
  recyclarr_config cleanuparr_config
  audiobookshelf_config audiobookshelf_metadata
  immich_db_data
  # open_webui_data holds every account and every saved conversation.
  # No longer near-empty: cache/ is now 2.2 GB of re-downloadable model
  # weights (embedding, whisper, tiktoken), against 820 KB of webui.db
  # and 184 KB of vector_db. See the exclusions below.
  open_webui_data
  # Added after an audit found them in no backup list at all. All small
  # (~19 MB combined). traefik_acme holds the ACME account key and the
  # issued wildcard: Traefik re-issues if it is lost, but that spends a
  # slot against Let's Encrypt's 5-duplicate-certificates-per-week limit.
  # crowdsec_config/crowdsec_data hold the bouncer and machine
  # registrations -- deleting one of those registrations took the site
  # down once already, so they are worth the few megabytes.
  traefik_acme crowdsec_config crowdsec_data
  files_cfg browse_cfg flood_data tdarr_configs tdarr_server
)

# Per-volume tar exclusions for content the app regenerates on its next
# library scan. This is not a size optimization for its own sake: an
# untrimmed snapshot ran ~8 GB, of which roughly 700 MB was irreplaceable
# (the databases and config files) and the rest was downloaded artwork.
# That bloat is what pushed the restic repo past B2's storage cap and
# silently broke the off-site backup.
#
# Rule of thumb: keep the .db files and config, drop anything the app
# re-fetches from TMDB/TVDB/MusicBrainz or re-derives from the media.
exclusions_for() {
  case "$1" in
    plex_config)
      # 3.5 GB of Metadata/Movies alone. Databases/ is the real payload:
      # watch history, library structure, play counts.
      printf '%s\n' \
        --exclude=./Library/Application*Support/Plex*Media*Server/Metadata \
        --exclude=./Library/Application*Support/Plex*Media*Server/Media \
        --exclude=./Library/Application*Support/Plex*Media*Server/Cache \
        --exclude=./Library/Application*Support/Plex*Media*Server/Logs \
        --exclude=./Library/Application*Support/Plex*Media*Server/Crash*Reports \
        --exclude=./Library/Application*Support/Plex*Media*Server/Scanners
      ;;
    sonarr_config|radarr_config|lidarr_config|readarr_config)
      # MediaCover is poster/fanart thumbnails, hundreds of numbered dirs.
      # radarr.db is 64 MB; its MediaCover was 2.5 GB.
      printf '%s\n' --exclude=./MediaCover --exclude=./logs --exclude=./Backups
      ;;
    prowlarr_config|bazarr_config|lazylibrarian_config)
      printf '%s\n' --exclude=./logs --exclude=./Backups
      ;;
    navidrome_config)
      printf '%s\n' --exclude=./cache
      ;;
    open_webui_data)
      # cache/ is 2.2 GB of re-downloadable model weights (embedding,
      # whisper, tiktoken) against 820 KB of webui.db and 184 KB of
      # vector_db. Excluding it makes this volume a rounding error.
      printf '%s\n' --exclude=./cache
      ;;
    tautulli_config)
      printf '%s\n' --exclude=./logs --exclude=./cache
      ;;
    *) : ;;
  esac
}

for vol in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "skip: volume '$vol' doesn't exist (not deployed?)"
    continue
  fi
  echo "backing up volume: $vol"
  # Alpine's built-in tar is BusyBox tar, which has no tolerance for a file
  # vanishing mid-archive -- a live app's SQLite WAL/SHM sidecar files get
  # deleted out from under it on a normal checkpoint, which isn't
  # corruption, just a benign race, but BusyBox tar treats it as fatal and
  # (with set -e) that killed the whole backup run partway through the
  # volume list. GNU tar (via --ignore-failed-read) demotes that specific
  # race to exit code 1 ("some files differ") instead of a hard error, but
  # set -e still treats any nonzero exit as fatal -- so exit 1 specifically
  # has to be tolerated here, while anything else (exit 2, a real error)
  # still aborts the run.
  docker run --rm \
    -v "${vol}:/volume:ro" \
    -v "${OUT}:/backup" \
    alpine \
    sh -c "apk add --no-cache tar >/dev/null 2>&1 && tar --ignore-failed-read $(exclusions_for "$vol" | tr '\n' ' ') -czf /backup/${vol}.tar.gz -C /volume ." \
    || { rc=$?; [ "$rc" -eq 1 ] || exit "$rc"; }
done

docker secret ls --format '{{.Name}}' > "$OUT/swarm-secret-names.txt" 2>/dev/null || true

echo "Local backup complete: $OUT"

# Prune anything older than 14 days
find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +14 -exec rm -rf {} \;
