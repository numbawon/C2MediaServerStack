#!/usr/bin/env bash
# DESTRUCTIVE. Deletes the entire restic repository from Backblaze B2 and
# re-initializes it empty.
#
# Why this exists: the repo grew to 9.75 GiB against a 10 GB free-tier
# cap, almost entirely from Plex/*arr artwork caches that should never
# have been backed up (see restic-excludes.txt). Once the cap tripped,
# B2 refused every upload, and restic cannot repair itself in that state
# because forget, prune and unlock all write a lock file first. Deletion
# does not need an upload, so purging is the only way out short of
# waiting for the daily cap reset at 00:00 UTC.
#
# ONLY run this while a known-good local backup exists. Check first:
#   ls -1 "$COMMON_BACKUP_LOCAL" | tail -3
#   for f in "$COMMON_BACKUP_LOCAL"/<newest>/*.tar.gz; do gzip -t "$f" || echo "CORRUPT $f"; done
#
# --b2-hard-delete matters: rclone's default on B2 hides files rather
# than removing them, and hidden versions still count toward stored
# bytes. Without it the purge would appear to succeed and free nothing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE="secrets/restic.env"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# b2:BUCKET:PATH -> BUCKET and PATH
BUCKET=$(echo "$RESTIC_REPOSITORY" | cut -d: -f2)
REPO_PATH=$(echo "$RESTIC_REPOSITORY" | cut -d: -f3)

rclone_run() {
  docker run --rm \
    -e RCLONE_CONFIG_B2_TYPE=b2 \
    -e RCLONE_CONFIG_B2_ACCOUNT="$B2_ACCOUNT_ID" \
    -e RCLONE_CONFIG_B2_KEY="$B2_ACCOUNT_KEY" \
    rclone/rclone "$@"
}

echo "Repository : b2:${BUCKET}:${REPO_PATH}"
echo "Current    : $(rclone_run size "b2:${BUCKET}/${REPO_PATH}" 2>/dev/null | tail -2 | tr '\n' ' ')"
echo
read -rp "Type DELETE to purge this repository: " confirm
[ "$confirm" = "DELETE" ] || { echo "Aborted."; exit 1; }

echo "==> purging (hard delete, so hidden versions go too)"
rclone_run purge --b2-hard-delete "b2:${BUCKET}/${REPO_PATH}"

echo "==> cleaning up any remaining old versions in the bucket"
rclone_run cleanup "b2:${BUCKET}" || true

echo "==> size after purge"
rclone_run size "b2:${BUCKET}/${REPO_PATH}" 2>/dev/null | tail -2 || echo "  (path gone, which is expected)"

echo
echo "==> re-initializing an empty repository"
docker run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
  restic/restic init

cat <<EOF

--------------------------------------------------------------------
Done. Next:

  ./scripts/backup-offsite.sh      # first trimmed backup, expect ~1 GB
  ./scripts/verify-backups.sh      # confirm it restores

Only after those pass should the local copies be deleted. Then the B2
caps can go back to \$0.00, since the repo should sit near 1 GB against
the 10 GB free allowance.
--------------------------------------------------------------------
EOF
