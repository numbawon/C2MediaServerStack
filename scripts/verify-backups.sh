#!/usr/bin/env bash
# Prove the off-site backup is actually restorable, rather than assuming
# it because the backup job exited 0.
#
# This exists because a backup that has never been restored is a
# hypothesis, not a backup. The README already told you to "actually run
# a restore periodically"; advice in a README is not a control, so this
# is the timer that does it.
#
# Two levels, on different cadences:
#
#   integrity (every run, weekly)
#     `restic check` verifies repository structure, and
#     `--read-data-subset` actually downloads and hashes a slice of the
#     real pack files. Structure-only checking would miss silent
#     corruption in B2, which is precisely the failure this guards.
#
#   restore (every RESTORE_INTERVAL_DAYS, default 28)
#     Restores one volume out of the newest snapshot into a scratch
#     directory and asserts the file count matches what the snapshot
#     says it should contain. This is the only step that proves the data
#     comes back, not just that it hashes correctly.
#
# Results are written as Prometheus metrics into the
# node_exporter_textfile volume, so a weekly job becomes something
# Prometheus can alert on continuously (see prometheus/rules/alerts.yml,
# BackupVerificationStale / BackupVerificationFailed).
#
# Run by systemd/mediastack-verify-backups.timer.
set -uo pipefail   # NOT -e: a failed check must still write its metrics

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE="secrets/restic.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE -- see scripts/backup-offsite.sh's header." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TEXTFILE_VOLUME="node_exporter_textfile"
METRIC_FILE="backup_verify.prom"
# Which volume to restore-test. Small enough to be cheap weekly-ish,
# real enough to be meaningful. prowlarr_config holds indexer
# definitions and API keys -- losing it is genuinely annoying, and it is
# a few MB rather than the tens of GB postgres_data or prometheus_data
# would pull down from B2 on every run.
# Which path inside the snapshot to restore-test. Small enough to be cheap,
# real enough to be meaningful: Prowlarr's config holds indexer definitions
# and API keys, and is a few MB rather than the tens of GB postgres_data or
# prometheus_data would pull down from B2 on every run.
#
# A full snapshot path, not a volume name. It used to be the latter, built
# as /data/${RESTORE_VOLUME}, which broke when the configs moved out of
# named volumes into .appdata: prowlarr_config no longer exists and the
# path is now /data/appdata/prowlarr. Anything migrated the same way needs
# the same shape.
RESTORE_PATH="${RESTORE_PATH:-/data/appdata/prowlarr}"
RESTORE_INTERVAL_DAYS="${RESTORE_INTERVAL_DAYS:-28}"

# Which database dump to prove restorable, and the Postgres major version to
# load it into. Authentik deliberately: losing that database locks you out of
# every service behind SSO, so it is the one whose recovery is worth proving.
# The image tag must match the server the dump came from; a dump from 16 will
# not load into 14.
DB_RESTORE_DUMP="${DB_RESTORE_DUMP:-authentik}"
DB_RESTORE_IMAGE="${DB_RESTORE_IMAGE:-postgres:16}"

RESTIC_ENV=(-e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY)

# Arguments go AFTER the image name or docker parses them as its own
# flags. restic_mounted takes one -v spec first, for the restore target.
restic_run() { docker run --rm "${RESTIC_ENV[@]}" restic/restic "$@"; }
restic_mounted() {
  local mount="$1"; shift
  docker run --rm "${RESTIC_ENV[@]}" -v "$mount" restic/restic "$@"
}

now=$(date +%s)

# Read a previous metric value out of the textfile volume, so the script
# can decide whether a restore test is due without a separate state file.
# The metrics file IS the state.
read_prev() {
  docker run --rm -v "${TEXTFILE_VOLUME}:/t" alpine:latest \
    sh -c "grep -m1 '^$1 ' /t/${METRIC_FILE} 2>/dev/null | awk '{print \$2}'" 2>/dev/null
}

# node-exporter reads any *.prom in the directory, so a half-written file
# would be parsed as garbage metrics. Write to a temp name and mv, which
# is atomic within the same filesystem.
write_metrics() {
  docker run --rm -i -v "${TEXTFILE_VOLUME}:/t" alpine:latest \
    sh -c "cat > /t/${METRIC_FILE}.tmp && mv /t/${METRIC_FILE}.tmp /t/${METRIC_FILE}"
}

integrity_ok=0
restore_ok=0
db_restore_ok=0
db_tables=0
db_expected_tables=0
restore_ran=0
restore_files=0
expected_files=0

# ---------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------
echo "==> restic check (structure + 5% of pack data)"
if restic_run check --read-data-subset=5%; then
  integrity_ok=1
  echo "    integrity OK"
else
  echo "    INTEGRITY FAILED" >&2
fi

# ---------------------------------------------------------------------
# Restore, on a longer cadence
# ---------------------------------------------------------------------
last_restore=$(read_prev mediastack_backup_verify_restore_last_success_timestamp_seconds)
last_restore=${last_restore%%.*}
[ -z "$last_restore" ] && last_restore=0
age_days=$(( (now - last_restore) / 86400 ))

if [ "$age_days" -ge "$RESTORE_INTERVAL_DAYS" ]; then
  restore_ran=1
  echo "==> restore test (last success ${age_days}d ago, interval ${RESTORE_INTERVAL_DAYS}d)"
  SCRATCH=$(mktemp -d)
  # restic runs as root inside its container, so the restored tree is
  # root-owned and this script (running as an ordinary user when invoked
  # by hand) cannot delete it. Clean up from inside a container instead,
  # which works whether or not the caller is root.
  cleanup_scratch() {
    [ -n "${SCRATCH:-}" ] || return 0
    docker run --rm -v "${SCRATCH}:/scratch" alpine:latest \
      sh -c 'rm -rf /scratch/..?* /scratch/.[!.]* /scratch/*' 2>/dev/null || true
    rmdir "$SCRATCH" 2>/dev/null || true
  }
  trap cleanup_scratch EXIT

  # What the snapshot claims to hold, so the assertion is against the
  # backup's own manifest rather than a number hardcoded here that would
  # silently rot as the config grows.
  #
  # --recursive matters: without it `restic ls` lists only the top level
  # (10 entries here, against 555 actual files) and the assertion fails
  # every time. --json plus a type filter matters too, because the plain
  # listing counts directories alongside files (561) while the restored
  # count from `find -type f` does not.
  expected_files=$(restic_run ls latest --json --recursive "${RESTORE_PATH}" 2>/dev/null \
    | grep -c '"type":"file"')

  # Zero means the path is not in the snapshot at all, which is a
  # different problem from a restore that failed, and that distinction is
  # the whole diagnosis. Say so, rather than letting it surface later as a
  # bare count mismatch.
  if [ "$expected_files" -eq 0 ]; then
    echo "    ${RESTORE_PATH} is not in the latest snapshot." >&2
    echo "    Either it stopped being backed up, or RESTORE_PATH is stale:" >&2
    echo "    config paths moved from /data/<volume> to /data/appdata/<app>" >&2
    echo "    when they left their named volumes." >&2
  fi

  if restic_mounted "${SCRATCH}:/restore" \
       restore latest --target /restore --include "${RESTORE_PATH}"; then
    restore_files=$(find "${SCRATCH}${RESTORE_PATH}" -type f 2>/dev/null | wc -l)
    echo "    restored ${restore_files} files, snapshot lists ${expected_files}"
    # Both must be non-zero: a snapshot that lists nothing would
    # otherwise "match" an empty restore and pass.
    if [ "$restore_files" -gt 0 ] && [ "$expected_files" -gt 0 ] \
       && [ "$restore_files" -eq "$expected_files" ]; then
      restore_ok=1
      last_restore=$now
      echo "    restore OK"
    else
      echo "    RESTORE ASSERTION FAILED" >&2
    fi
  else
    echo "    RESTORE COMMAND FAILED" >&2
  fi

  # -------------------------------------------------------------------
  # Database restore, into a throwaway server
  #
  # The file restore above proves a directory tree comes back. It says
  # nothing about whether a database does, and those fail differently: a
  # dump can be present, correctly sized and valid gzip while still being
  # unloadable. The only way to know is to load it.
  #
  # Authentik's by default, because losing that database locks you out of
  # every service behind SSO.
  #
  # The server is a disposable container with no volume, so this cannot
  # touch the running stack even if the dump is malformed.
  # -------------------------------------------------------------------
  DB_DUMP_PATH="/data/dbdumps/${DB_RESTORE_DUMP}.sql.gz"
  DB_TEST_CONTAINER="verify-dbrestore-$$"

  cleanup_dbtest() {
    docker rm -f "$DB_TEST_CONTAINER" >/dev/null 2>&1 || true
  }
  trap 'cleanup_dbtest; cleanup_scratch' EXIT

  echo "==> database restore test (${DB_RESTORE_DUMP} into ${DB_RESTORE_IMAGE})"

  if restic_mounted "${SCRATCH}:/restore" \
       restore latest --target /restore --include "${DB_DUMP_PATH}" >/dev/null 2>&1 \
     && [ -s "${SCRATCH}${DB_DUMP_PATH}" ]; then

    # What the dump says it holds, so the assertion is against the dump
    # itself rather than a number hardcoded here that would rot.
    db_expected_tables=$(gzip -dc "${SCRATCH}${DB_DUMP_PATH}" 2>/dev/null \
      | grep -c "^CREATE TABLE" || true)

    # POSTGRES_USER/DB match the dump's owner and database name, which
    # dump-databases.sh keeps identical to the label. Without the role the
    # OWNER TO statements fail and the tables land unowned.
    if docker run -d --rm --name "$DB_TEST_CONTAINER" \
         -e POSTGRES_PASSWORD=verify \
         -e POSTGRES_USER="${DB_RESTORE_DUMP}" \
         -e POSTGRES_DB="${DB_RESTORE_DUMP}" \
         "$DB_RESTORE_IMAGE" >/dev/null 2>&1; then

      ready=0
      for _ in $(seq 1 60); do
        if docker exec "$DB_TEST_CONTAINER" pg_isready -U "${DB_RESTORE_DUMP}" \
             >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 2
      done

      if [ "$ready" -eq 1 ]; then
        # ON_ERROR_STOP is deliberately off: the dump carries --clean
        # --if-exists, so its DROP statements fail harmlessly against a
        # fresh database. The table count below is the real assertion.
        gzip -dc "${SCRATCH}${DB_DUMP_PATH}" 2>/dev/null \
          | docker exec -i "$DB_TEST_CONTAINER" \
              psql -U "${DB_RESTORE_DUMP}" -d "${DB_RESTORE_DUMP}" -q >/dev/null 2>&1 || true

        # Every user schema, not just public. Authentik keeps 230 tables in
        # public and another 155 in a `template` schema; counting only
        # public compared 230 against the dump's 385 CREATE TABLE lines and
        # failed a restore that had in fact worked perfectly. Both sides
        # have to be counted the same way.
        db_tables=$(docker exec "$DB_TEST_CONTAINER" psql -U "${DB_RESTORE_DUMP}" \
          -d "${DB_RESTORE_DUMP}" -tAc \
          "select count(*) from information_schema.tables
             where table_schema not in ('pg_catalog','information_schema')" \
          2>/dev/null | tr -d '[:space:]')
        db_tables=${db_tables:-0}

        echo "    loaded ${db_tables} tables, dump declares ${db_expected_tables}"
        if [ "$db_tables" -gt 0 ] && [ "$db_expected_tables" -gt 0 ] \
           && [ "$db_tables" -eq "$db_expected_tables" ]; then
          db_restore_ok=1
          echo "    database restore OK"
        else
          echo "    DATABASE RESTORE ASSERTION FAILED" >&2
        fi
      else
        echo "    throwaway Postgres never became ready" >&2
      fi
    else
      echo "    could not start the throwaway Postgres" >&2
    fi
  else
    echo "    ${DB_DUMP_PATH} is not in the latest snapshot," >&2
    echo "    or restored empty. Databases are dumped by" >&2
    echo "    scripts/dump-databases.sh, called from both backup jobs." >&2
  fi
  cleanup_dbtest

  cleanup_scratch
  trap - EXIT
else
  echo "==> restore test skipped (last success ${age_days}d ago, interval ${RESTORE_INTERVAL_DAYS}d)"
  # Carry the previous success forward so the staleness alert measures
  # the real last-restore, not the last time this branch was skipped.
  restore_ok=$(read_prev mediastack_backup_verify_restore_success)
  restore_ok=${restore_ok%%.*}
  [ -z "$restore_ok" ] && restore_ok=0
  # Same for the database result: a skipped run must not read as a failure.
  db_restore_ok=$(read_prev mediastack_backup_verify_db_restore_success)
  db_restore_ok=${db_restore_ok%%.*}
  [ -z "$db_restore_ok" ] && db_restore_ok=0
fi

snapshot_count=$(restic_run snapshots --json 2>/dev/null | grep -o '"time"' | wc -l)

write_metrics <<EOF
# HELP mediastack_backup_verify_last_run_timestamp_seconds Unix time of the last verification run.
# TYPE mediastack_backup_verify_last_run_timestamp_seconds gauge
mediastack_backup_verify_last_run_timestamp_seconds ${now}
# HELP mediastack_backup_verify_integrity_success Whether restic check passed on the last run.
# TYPE mediastack_backup_verify_integrity_success gauge
mediastack_backup_verify_integrity_success ${integrity_ok}
# HELP mediastack_backup_verify_restore_success Whether the most recent restore test passed.
# TYPE mediastack_backup_verify_restore_success gauge
mediastack_backup_verify_restore_success ${restore_ok}
# HELP mediastack_backup_verify_restore_last_success_timestamp_seconds Unix time of the last successful restore test.
# TYPE mediastack_backup_verify_restore_last_success_timestamp_seconds gauge
mediastack_backup_verify_restore_last_success_timestamp_seconds ${last_restore}
# HELP mediastack_backup_verify_restore_ran Whether a restore test ran this time (0 means it was not due).
# TYPE mediastack_backup_verify_restore_ran gauge
mediastack_backup_verify_restore_ran ${restore_ran}
# HELP mediastack_backup_verify_restored_files Files restored in the last restore test.
# TYPE mediastack_backup_verify_restored_files gauge
mediastack_backup_verify_restored_files ${restore_files}
# HELP mediastack_backup_verify_expected_files Files the snapshot manifest listed for the tested volume.
# TYPE mediastack_backup_verify_expected_files gauge
mediastack_backup_verify_expected_files ${expected_files}
# HELP mediastack_backup_verify_db_restore_success Whether a database dump loaded into a throwaway server and matched its own table count.
# TYPE mediastack_backup_verify_db_restore_success gauge
mediastack_backup_verify_db_restore_success ${db_restore_ok}
# HELP mediastack_backup_verify_db_tables Tables present after loading the dump.
# TYPE mediastack_backup_verify_db_tables gauge
mediastack_backup_verify_db_tables ${db_tables}
# HELP mediastack_backup_verify_db_expected_tables Tables the dump itself declares.
# TYPE mediastack_backup_verify_db_expected_tables gauge
mediastack_backup_verify_db_expected_tables ${db_expected_tables}
# HELP mediastack_backup_verify_snapshots Snapshots currently in the repository.
# TYPE mediastack_backup_verify_snapshots gauge
mediastack_backup_verify_snapshots ${snapshot_count}
EOF

echo "==> metrics written to ${TEXTFILE_VOLUME}/${METRIC_FILE}"

# Non-zero exit so `systemctl status` and journald show a failure too,
# not only Prometheus. Metrics are already written by this point.
if [ "$integrity_ok" -ne 1 ] || { [ "$restore_ran" -eq 1 ] && [ "$restore_ok" -ne 1 ]; }; then
  echo "VERIFICATION FAILED" >&2
  exit 1
fi
echo "verification passed"
