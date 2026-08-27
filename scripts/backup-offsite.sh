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
  # ntfy_data holds every ntfy account and access token, including the
  # one configured in the phone's custom headers -- losing it means
  # re-issuing and re-entering them by hand.
  alertmanager_data ntfy_data diun_data
)

MOUNT_ARGS=()
PATHS=()
for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    MOUNT_ARGS+=(-v "${vol}:/data/${vol}:ro")
    PATHS+=("/data/${vol}")
  fi
done

# secrets/ is git-ignored by design, which also means it exists in
# exactly one place: this disk. Everything else here is a Docker volume,
# so a disk failure would take the WireGuard private key, the Plex claim
# token, the ntfy passwords and the Cloudflare Access service token with
# it, and several of those cannot simply be regenerated without also
# reconfiguring the device that uses them.
#
# Deliberately off-site only, not in backup-local.sh: restic encrypts
# with RESTIC_PASSWORD before anything leaves the host, whereas the local
# job would just write a second plaintext copy onto the same disk.
#
# Yes, this includes secrets/restic.env, so the repository contains its
# own password. That is circular but harmless: you already need the
# password to decrypt anything, so it grants a reader nothing new. Keep
# RESTIC_PASSWORD somewhere outside this machine as well.
if [ -d secrets ]; then
  MOUNT_ARGS+=(-v "$(pwd)/secrets:/data/secrets:ro")
  PATHS+=("/data/secrets")
fi

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
