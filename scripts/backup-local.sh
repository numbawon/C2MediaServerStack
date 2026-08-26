#!/usr/bin/env bash
# Fast local snapshot of every app's config volume. Does NOT back up media
# (/mnt/Storage/Media) -- too large, and it's not ephemeral state. Does NOT
# back up secret values either (Swarm secrets can't be exported by design) --
# that's what scripts/backup-offsite.sh + init-secrets.sh together cover:
# restic keeps an encrypted, restorable copy; a lost Swarm secret can also
# just be recreated with init-secrets.sh since most are random passwords
# apps rewrite state around, not user-chosen values.
set -euo pipefail

DEST="${1:-/mnt/Storage/Backups/local}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="$DEST/$STAMP"
mkdir -p "$OUT"

VOLUMES=(
  authentik_data pihole_config pihole_dnsmasq portainer_data postgres_data
  prometheus_data grafana_data sonarr_config radarr_config lidarr_config
  bazarr_config seerr_config lazylibrarian_config prowlarr_config
  tautulli_config navidrome_config loki_data organizarr_data
  qbittorrent_config plex_config
)

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
    sh -c "apk add --no-cache tar >/dev/null 2>&1 && tar --ignore-failed-read -czf /backup/${vol}.tar.gz -C /volume ." \
    || { rc=$?; [ "$rc" -eq 1 ] || exit "$rc"; }
done

docker secret ls --format '{{.Name}}' > "$OUT/swarm-secret-names.txt" 2>/dev/null || true

echo "Local backup complete: $OUT"

# Prune anything older than 14 days
find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +14 -exec rm -rf {} \;
