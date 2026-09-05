#!/usr/bin/env bash
# Move a named Docker volume's contents into ./.appdata/<name>/ so the files
# are reachable and editable on the host without docker exec.
#
# WHY .appdata LIVES IN THE REPO AND NOT UNDER /mnt/Media
#
# The obvious home was ${COMMON_APPDATA} (/mnt/Media/.appdata), which is
# where immich, ollama and tdarr already keep theirs. It is the wrong place
# for anything an app trusts: the `files` service serves /mnt/Media
# read-write, so a config living there is editable by anyone who gets
# through that UI. An *arr's config.xml holds its API key; Pi-hole's holds
# its admin settings. Those must not be reachable from a file browser.
#
# The repo directory is not served by anything, so configs here are reachable
# over SSH and nothing else. .appdata is gitignored: these are runtime state,
# not declarative config, and several of them contain credentials.
#
# WHAT THIS DOES NOT DO
#
# It does not edit docker-stack.yml and it does not redeploy. It copies and
# verifies, so the copy can be checked before the mount is switched. The
# service must already be stopped: copying a live SQLite database yields a
# file that looks fine and is subtly torn.
#
# NAMING
#
# The destination drops the redundant suffix: navidrome_config becomes
# .appdata/navidrome, since the directory's parent already says these are
# configs. Apps with more than one volume nest instead of colliding, so
# crowdsec_config and crowdsec_data become .appdata/crowdsec/config and
# .appdata/crowdsec/data. Pass an explicit destination for those.
#
# Usage:
#   scripts/migrate-volume-to-appdata.sh <volume>[:<dest>] [...]
#
# Examples:
#   ... navidrome_config              -> .appdata/navidrome
#   ... crowdsec_config:crowdsec/config crowdsec_data:crowdsec/data
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
APPDATA="$(pwd)/.appdata"

if [ $# -lt 1 ]; then
  echo "usage: $0 <volume>[:<dest>] [<volume>[:<dest>]...]" >&2
  exit 64
fi

# volume name -> directory name, unless one was given explicitly.
#
# This strips one trailing _word, so it is right for the common single
# volume per app (navidrome_config -> navidrome) and wrong for anything
# with a compound name: immich_db_data would become immich_db, and
# tdarr_configs becomes tdarr while its sibling tdarr_server does not.
# Those cases are exactly the ones that need an explicit dest anyway,
# since two volumes cannot share one directory.
dest_for() {
  case "$1" in
    *_config|*_configs|*_data|*_cfg) echo "${1%_*}" ;;
    *) echo "$1" ;;
  esac
}

mkdir -p "$APPDATA"
# Not world-readable: several of these hold API keys and admin credentials.
chmod 700 "$APPDATA"

rc=0
for arg in "$@"; do
  vol="${arg%%:*}"
  if [ "$arg" = "$vol" ]; then
    name="$(dest_for "$vol")"
  else
    name="${arg#*:}"
  fi
  echo "==> $vol -> .appdata/$name"

  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "    volume does not exist, skipping"
    continue
  fi

  # Refuse to copy out from under a running container. Anything holding the
  # volume open is almost certainly mid-write to a SQLite file.
  users=$(docker ps --format '{{.Names}}' --filter "volume=$vol" | tr '\n' ' ')
  if [ -n "${users// /}" ]; then
    echo "    STILL IN USE by: ${users}" >&2
    echo "    stop it first, or the copy will be torn" >&2
    rc=1
    continue
  fi

  dest="$APPDATA/$name"
  if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "    $dest already exists and is not empty, skipping"
    continue
  fi
  mkdir -p "$dest"

  # Copy inside a container so ownership and modes survive regardless of who
  # runs this. -a preserves them; the trailing /. copies dotfiles too.
  docker run --rm \
    -v "${vol}:/from:ro" \
    -v "${dest}:/to" \
    alpine:latest sh -c 'cp -a /from/. /to/ 2>/dev/null; exit 0'

  # Verify by file count and byte total rather than trusting cp's exit code,
  # which stays 0 for a partial copy of an unreadable subtree.
  read -r src_files src_bytes <<<"$(docker run --rm -v "${vol}:/v:ro" alpine:latest \
      sh -c 'find /v -type f | wc -l; du -sb /v | cut -f1' | tr '\n' ' ')"
  read -r dst_files dst_bytes <<<"$(docker run --rm -v "${dest}:/v:ro" alpine:latest \
      sh -c 'find /v -type f | wc -l; du -sb /v | cut -f1' | tr '\n' ' ')"

  printf '    source %s files, %s bytes\n' "$src_files" "$src_bytes"
  printf '    copy   %s files, %s bytes\n' "$dst_files" "$dst_bytes"

  if [ "$src_files" = "$dst_files" ] && [ "$src_bytes" = "$dst_bytes" ]; then
    echo "    OK, identical"
  else
    echo "    MISMATCH, do not switch the mount for this one" >&2
    rc=1
  fi
done

echo
echo "The original volumes are untouched. Switch the mounts in docker-stack.yml,"
echo "redeploy, verify the apps, and only then remove the old volumes."
exit $rc
