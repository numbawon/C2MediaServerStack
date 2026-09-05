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

# .env too, for COMMON_APPDATA. Without this that variable is unset, and the
# guard below is a `-n` test, so the whole media-appdata path was silently
# skipped: the first run after it was added produced a snapshot with no
# /data/media-appdata in it at all, and nothing said so. backup-local.sh has
# always sourced .env, which is why the same block worked there and hid the
# problem.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

VOLUMES=(
  authentik_data postgres_data prometheus_data pinepods_db_data
  immich_db_data traefik_acme
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
  # ntfy_data holds every ntfy account and access token, including the
  # one configured in the phone's custom headers -- losing it means
  # re-issuing and re-entering them by hand.
  # Stage 3. immich_db_data is the important one: it holds every photo's
  # metadata, albums, faces and search embeddings. The photo FILES live on
  # a media path and are not in here.
  # open_webui_data holds every account and saved conversation, but
  # 2.2 GB of its 2.2 GB is cache/ -- re-downloadable embedding,
  # whisper and tiktoken model weights. webui.db is 820 KB and
  # vector_db 184 KB, so with cache/ excluded (restic-excludes.txt)
  # the real content is under a megabyte. It was left out of this
  # list while it looked like a 2.2 GB decision; it was never one.
  # Added after an audit found them in no backup list at all. All small
  # (~19 MB combined). traefik_acme holds the ACME account key and the
  # issued wildcard: Traefik re-issues if it is lost, but that spends a
  # slot against Let's Encrypt's 5-duplicate-certificates-per-week limit.
  # crowdsec_config/crowdsec_data hold the bouncer and machine
  # registrations -- deleting one of those registrations took the site
  # down once already, so they are worth the few megabytes.
  # PinePods subscriptions, per-user progress and playlists. Its
  # downloads/ and backups/ volumes are deliberately absent: the first
  # is re-fetchable media, the second is its own export directory.
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

# App config migrated out of named volumes into ./.appdata so it is
# editable on the host (see scripts/migrate-volume-to-appdata.sh). Same
# data as before, different location, so it has to be covered here or the
# migration would quietly delete these from the backup set.
#
# Directory names match the volume names they replaced, which keeps the
# restic paths stable across the move.
if [ -d .appdata ]; then
  MOUNT_ARGS+=(-v "$(pwd)/.appdata:/data/appdata:ro")
  PATHS+=("/data/appdata")
fi

# COMMON_APPDATA (/mnt/Media/.appdata) holds immich's managed store and
# tdarr's config, and was in NEITHER backup script until this was noticed:
# both iterate named volumes only, and these are bind mounts. Immich's is
# ~270 MB of real state.
#
# ollama's subdirectory is excluded in restic-excludes.txt: 12 GB of model
# weights that re-download with one `ollama pull`.
if [ -n "${COMMON_APPDATA:-}" ] && [ -d "$COMMON_APPDATA" ]; then
  MOUNT_ARGS+=(-v "${COMMON_APPDATA}:/data/media-appdata:ro")
  PATHS+=("/data/media-appdata")
fi

# Logical database dumps, for the same reason as in backup-local.sh: the
# data directories above are tarred live, and a torn one restores into a
# cluster that may not start. Written to a temp directory and mounted in,
# since restic backs up paths rather than commands.
#
# Deliberately not fatal: a failed dump should not cost you the rest of the
# off-site backup. The metrics and the missing files are the signal.
DUMP_DIR="$(mktemp -d)"
cleanup_dumps() { [ -n "${DUMP_DIR:-}" ] && rm -rf "$DUMP_DIR"; }
trap cleanup_dumps EXIT

echo "==> dumping databases"
if ./scripts/dump-databases.sh "$DUMP_DIR"; then
  MOUNT_ARGS+=(-v "${DUMP_DIR}:/data/dbdumps:ro")
  PATHS+=("/data/dbdumps")
else
  echo "WARNING: one or more database dumps failed; continuing without them" >&2
  # Still include whatever did succeed rather than dropping all three.
  if [ -n "$(ls -A "$DUMP_DIR" 2>/dev/null)" ]; then
    MOUNT_ARGS+=(-v "${DUMP_DIR}:/data/dbdumps:ro")
    PATHS+=("/data/dbdumps")
  fi
fi

if [ "${#PATHS[@]}" -eq 0 ]; then
  echo "No volumes found to back up -- is the stack deployed?" >&2
  exit 1
fi

# Report the outcome as Prometheus metrics via node-exporter's textfile
# collector. Without this, a failing backup is INVISIBLE: verify-backups.sh
# checks that STORED snapshots are restorable, which keeps passing happily
# while the nightly upload fails. That is exactly what happened when B2's
# storage cap was hit -- the job failed for days while every alert read
# healthy, because nothing watched whether the job itself succeeded.
TEXTFILE_VOLUME="node_exporter_textfile"
METRIC_FILE="backup_offsite.prom"

write_metrics() {
  # Atomic: node-exporter parses any *.prom in the directory, and a
  # half-written file yields garbage metrics.
  docker run --rm -i -v "${TEXTFILE_VOLUME}:/t" alpine:latest \
    sh -c "cat > /t/${METRIC_FILE}.tmp && mv /t/${METRIC_FILE}.tmp /t/${METRIC_FILE}" 2>/dev/null || true
}

read_prev_success() {
  docker run --rm -v "${TEXTFILE_VOLUME}:/t" alpine:latest \
    sh -c "grep -m1 '^mediastack_backup_last_success_timestamp_seconds ' /t/${METRIC_FILE} 2>/dev/null | awk '{print \$2}'" 2>/dev/null
}

# init is a no-op (with a warning) if the repo already exists
docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  restic/restic init 2>/dev/null || true

# Not under `set -e`: a failure here must still write its metrics, or the
# alert this exists to raise never fires.
backup_rc=0
docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  "${MOUNT_ARGS[@]}" \
  -v "$(pwd)/restic-excludes.txt:/excludes.txt:ro" \
  restic/restic backup --exclude-file=/excludes.txt "${PATHS[@]}" || backup_rc=$?

now=$(date +%s)
last_success=$(read_prev_success)
last_success=${last_success%%.*}
[ -z "$last_success" ] && last_success=0
[ "$backup_rc" -eq 0 ] && last_success=$now

write_metrics <<METRICS
# HELP mediastack_backup_last_run_timestamp_seconds Unix time the off-site backup last ran.
# TYPE mediastack_backup_last_run_timestamp_seconds gauge
mediastack_backup_last_run_timestamp_seconds ${now}
# HELP mediastack_backup_success Whether the last off-site backup run succeeded.
# TYPE mediastack_backup_success gauge
mediastack_backup_success $([ "$backup_rc" -eq 0 ] && echo 1 || echo 0)
# HELP mediastack_backup_last_success_timestamp_seconds Unix time of the last SUCCESSFUL off-site backup.
# TYPE mediastack_backup_last_success_timestamp_seconds gauge
mediastack_backup_last_success_timestamp_seconds ${last_success}
METRICS

if [ "$backup_rc" -ne 0 ]; then
  echo "Off-site backup FAILED (exit ${backup_rc}); metrics written." >&2
  exit "$backup_rc"
fi

# --group-by '' matters: restic groups by host,paths BY DEFAULT, and this
# script's path list grows every time a service is added (16 -> 15 -> 20 ->
# 29 paths so far). Each distinct path set becomes its own group, so a
# retention policy is applied per-group and keeps the newest of each --
# meaning old snapshots are never actually expired. That is how the repo
# reached 10 GiB and tripped B2's cap while appearing to prune nightly.
docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  restic/restic forget --group-by '' \
    --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune

echo "Off-site backup complete."
