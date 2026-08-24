#!/usr/bin/env bash
# Fast local snapshot of every app's config volume. Does NOT back up media
# (/mnt/Storage/Media) — too large, and it's not ephemeral state. Does NOT
# back up secret values either (Swarm secrets can't be exported by design) —
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
  bazarr_config overseerr_config lazylibrarian_config
  qbittorrent_config plex_config
)

for vol in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "skip: volume '$vol' doesn't exist (not deployed?)"
    continue
  fi
  echo "backing up volume: $vol"
  docker run --rm \
    -v "${vol}:/volume:ro" \
    -v "${OUT}:/backup" \
    alpine \
    tar czf "/backup/${vol}.tar.gz" -C /volume .
done

docker secret ls --format '{{.Name}}' > "$OUT/swarm-secret-names.txt" 2>/dev/null || true

echo "Local backup complete: $OUT"

# Prune anything older than 14 days
find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +14 -exec rm -rf {} \;
