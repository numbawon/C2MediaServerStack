#!/usr/bin/env bash
# Encrypted off-site backup via restic -> Backblaze B2. Run by a systemd
# timer (see README for the unit files). Backs up the same config volumes as
# backup-local.sh, run through restic's own container so nothing needs
# installing on the host besides Docker.
#
# Reads credentials from secrets/restic.env (git-ignored, chmod 600):
#   RESTIC_REPOSITORY=b2:your-bucket-name:mediastack
#   RESTIC_PASSWORD=<a password only you know -- losing this loses the backup>
#   B2_ACCOUNT_ID=<Backblaze application key ID>
#   B2_ACCOUNT_KEY=<Backblaze application key>
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE="secrets/restic.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE -- create it first (see this script's header comment)." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

VOLUMES=(
  authentik_data pihole_config pihole_dnsmasq portainer_data postgres_data
  prometheus_data grafana_data sonarr_config radarr_config lidarr_config
  bazarr_config seerr_config lazylibrarian_config prowlarr_config
  tautulli_config navidrome_config loki_data organizarr_data
  qbittorrent_config plex_config
)

MOUNT_ARGS=()
PATHS=()
for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    MOUNT_ARGS+=(-v "${vol}:/data/${vol}:ro")
    PATHS+=("/data/${vol}")
  fi
done

if [ "${#PATHS[@]}" -eq 0 ]; then
  echo "No volumes found to back up -- is the stack deployed?" >&2
  exit 1
fi

# init is a no-op (with a warning) if the repo already exists
docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  restic/restic init 2>/dev/null || true

docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  "${MOUNT_ARGS[@]}" \
  restic/restic backup "${PATHS[@]}"

docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  restic/restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune

echo "Off-site backup complete."
