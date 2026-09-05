#!/usr/bin/env bash
# Logical pg_dump of every Postgres in the stack, into <target-dir>.
#
# WHY, GIVEN THE DATA DIRECTORIES ARE ALREADY BACKED UP
#
# They are backed up by tarring a LIVE data directory. Every run prints
# something like "tar: ./base/16384/23654: file changed as we read it",
# which is Postgres writing while tar reads. Because the whole PGDATA
# including pg_wal is captured, restoring one behaves like recovery from an
# unclean shutdown, and Postgres usually handles that. Usually is doing a
# lot of work in that sentence: a file torn mid-write can leave a cluster
# that will not start, and you find out at restore time.
#
# A logical dump has no such problem. It runs inside a transaction against a
# consistent snapshot, and it restores into any compatible server rather than
# needing a byte-identical one. The two are kept side by side deliberately:
# the tarball is faster to restore and preserves everything, the dump is the
# one that is guaranteed to be coherent.
#
# It also covers a gap the restore test cannot reach. scripts/verify-backups.sh
# proves a file tree comes back (Prowlarr's config); nothing was proving a
# database could.
#
# pg_dump runs INSIDE each container, so its version always matches the
# server it is dumping. Running it from the host would break the moment two
# servers disagreed, and here there are three: 16, 18 and 14.
#
# Usage: dump-databases.sh <target-dir>
# Exit:  0 all dumps written and verified, 1 if any failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <target-dir>" >&2
  exit 64
fi
mkdir -p "$TARGET"

# label:service-name-filter. The user and database come from the container's
# own POSTGRES_USER/POSTGRES_DB, so this does not drift when they change.
DATABASES=(
  "authentik:mediastack_postgres."
  "pinepods:mediastack_pinepods-postgres."
  "immich:mediastack_immich-postgres."
)

rc=0
for entry in "${DATABASES[@]}"; do
  label="${entry%%:*}"
  filter="${entry#*:}"

  container=$(docker ps --filter "name=${filter}" --format '{{.Names}}' | head -1)
  if [ -z "$container" ]; then
    echo "  ${label}: no running container matching ${filter}, SKIPPED" >&2
    rc=1
    continue
  fi

  user=$(docker exec "$container" printenv POSTGRES_USER 2>/dev/null)
  db=$(docker exec "$container" printenv POSTGRES_DB 2>/dev/null)
  if [ -z "$user" ] || [ -z "$db" ]; then
    echo "  ${label}: could not read POSTGRES_USER/POSTGRES_DB, SKIPPED" >&2
    rc=1
    continue
  fi

  out="${TARGET}/${label}.sql.gz"
  # --clean --if-exists so the dump can be replayed into a non-empty
  # database without hand-editing it first.
  if docker exec "$container" pg_dump -U "$user" -d "$db" --clean --if-exists 2>/dev/null \
       | gzip -c > "$out"; then
    :
  else
    echo "  ${label}: pg_dump FAILED" >&2
    rm -f "$out"
    rc=1
    continue
  fi

  # Verify rather than trust the exit status. A dump that is valid gzip but
  # holds no schema is the failure mode worth catching: it looks like a file
  # and restores to nothing.
  if ! gzip -t "$out" 2>/dev/null; then
    echo "  ${label}: dump is not valid gzip" >&2
    rm -f "$out"
    rc=1
    continue
  fi
  tables=$(gzip -dc "$out" 2>/dev/null | grep -c "^CREATE TABLE" || true)
  size=$(stat -c %s "$out" 2>/dev/null || echo 0)
  if [ "${tables:-0}" -lt 1 ]; then
    echo "  ${label}: dump contains no CREATE TABLE, refusing to call it good" >&2
    rm -f "$out"
    rc=1
    continue
  fi
  printf '  %-10s %s tables, %s bytes gzipped\n' "$label" "$tables" "$size"

  # Roles and other cluster-wide objects live outside any one database, so a
  # per-database dump alone restores tables that nothing has permission to
  # read. Small, and only worth having next to the dumps it belongs with.
  globals="${TARGET}/${label}-globals.sql.gz"
  docker exec "$container" pg_dumpall -U "$user" --globals-only 2>/dev/null \
    | gzip -c > "$globals" || true
  [ -s "$globals" ] || rm -f "$globals"
done

exit "$rc"
