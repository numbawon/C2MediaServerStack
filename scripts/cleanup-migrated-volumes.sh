#!/usr/bin/env bash
# Remove the Docker volumes left behind by the .appdata migration, but only
# once the new location has actually proven itself.
#
# WHY THIS IS A SCRIPT AND NOT A ONE-LINER
#
# The migration copied ~14 GB of config out of named volumes into .appdata
# and deliberately left the originals in place. Deleting them is the point
# at which the migration stops being reversible, so the condition for doing
# it is "three SUCCESSFUL backup cycles have captured the new location",
# not "three days have passed". Those differ exactly when it matters: if
# the off-site job has been failing all week, elapsed time looks fine and
# the fallbacks are the only intact copy.
#
# So this refuses to delete anything unless, per volume:
#   - nothing currently mounts it
#   - the matching .appdata directory exists and is non-empty
#   - there have been >= REQUIRED_CYCLES successful off-site backups since
#     the migration marker
#
# --status reports where things stand and changes nothing. Without --force
# it is a dry run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

MARKER=".appdata/.migrated-at"
REQUIRED_CYCLES="${REQUIRED_CYCLES:-3}"
LOCAL_DEST="${COMMON_BACKUP_LOCAL:-/mnt/Storage/.backups/local}"

force=0
status_only=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --status) status_only=1 ;;
    *) echo "usage: $0 [--status] [--force]" >&2; exit 64 ;;
  esac
done

if [ ! -f "$MARKER" ]; then
  echo "No $MARKER. Nothing has been migrated, or the marker was lost." >&2
  exit 1
fi
migrated_at="$(cat "$MARKER")"
echo "Migration marker: $(date -d "@$migrated_at" 2>/dev/null || echo "$migrated_at")"

# ---------------------------------------------------------------------
# How many successful backup cycles since the migration
#
# restic snapshots are the meaningful count: they are the off-site copy,
# and a snapshot only exists if that run actually completed. The local
# count is reported too but is not the gate, since local backups live on
# the same machine as the thing they protect.
# ---------------------------------------------------------------------
offsite=0
if [ -f secrets/restic.env ]; then
  set -a
  # shellcheck disable=SC1091
  source secrets/restic.env
  set +a
  offsite=$(docker run --rm \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
    restic/restic snapshots --json 2>/dev/null \
    | python3 -c "
import sys, json, datetime
try:
    snaps = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
cut = int(sys.argv[1])
n = 0
for s in snaps:
    t = s.get('time', '')[:19]
    try:
        ts = datetime.datetime.fromisoformat(t).timestamp()
    except ValueError:
        continue
    if ts >= cut:
        n += 1
print(n)
" "$migrated_at" 2>/dev/null || echo 0)
fi

local_runs=0
if [ -d "$LOCAL_DEST" ]; then
  local_runs=$(find "$LOCAL_DEST" -maxdepth 1 -mindepth 1 -type d -newermt "@$migrated_at" 2>/dev/null | wc -l)
fi

echo "Successful off-site cycles since then: $offsite (need $REQUIRED_CYCLES)"
echo "Local snapshots since then:            $local_runs"
echo

# ---------------------------------------------------------------------
# Per-volume eligibility
# ---------------------------------------------------------------------
mounted_volumes() {
  docker ps -a --format '{{.Names}}' | while read -r c; do
    docker inspect "$c" -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null
  done | sort -u
}
in_use="$(mounted_volumes)"

# volume name -> .appdata directory it was migrated to.
#
# An EXPLICIT list, deliberately. An earlier version fell back to stripping
# the volume's trailing _word and treating "the directory exists" as proof
# it had been migrated. That maps suricata_logs onto .appdata/suricata and
# tdarr_logs onto .appdata/tdarr, so two live log volumes that were never
# migrated showed up as deletion candidates. Only the still-mounted check
# stood between that and data loss. Anything not named here is left alone.
appdata_for() {
  case "$1" in
    sonarr_config) echo "sonarr" ;;
    radarr_config) echo "radarr" ;;
    lidarr_config) echo "lidarr" ;;
    bazarr_config) echo "bazarr" ;;
    prowlarr_config) echo "prowlarr" ;;
    lazylibrarian_config) echo "lazylibrarian" ;;
    navidrome_config) echo "navidrome" ;;
    seerr_config) echo "seerr" ;;
    tautulli_config) echo "tautulli" ;;
    recyclarr_config) echo "recyclarr" ;;
    cleanuparr_config) echo "cleanuparr" ;;
    qbittorrent_config) echo "qbittorrent" ;;
    plex_config) echo "plex" ;;
    portainer_data) echo "portainer" ;;
    grafana_data) echo "grafana" ;;
    alertmanager_data) echo "alertmanager" ;;
    organizarr_data) echo "organizarr" ;;
    ntfy_data) echo "ntfy" ;;
    diun_data) echo "diun" ;;
    flood_data) echo "flood" ;;
    mediastack_flood_data) echo "flood" ;;
    files_cfg) echo "files" ;;
    browse_cfg) echo "browse" ;;
    suricata_config) echo "suricata" ;;
    open_webui_data) echo "open_webui" ;;
    mediastack_beets_config) echo "beets" ;;
    crowdsec_config) echo "crowdsec/config" ;;
    crowdsec_data) echo "crowdsec/data" ;;
    audiobookshelf_config) echo "audiobookshelf/config" ;;
    audiobookshelf_metadata) echo "audiobookshelf/metadata" ;;
    pihole_config) echo "pihole/config" ;;
    pihole_dnsmasq) echo "pihole/dnsmasq" ;;
    tdarr_configs) echo "tdarr/configs" ;;
    tdarr_server) echo "tdarr/server" ;;
    *) echo "" ;;
  esac
}

eligible=()
blocked=0
for vol in $(docker volume ls -q | sort); do
  # ignore anonymous volumes
  [[ "$vol" =~ ^[0-9a-f]{64}$ ]] && continue

  # only consider volumes this migration actually replaced
  sub="$(appdata_for "$vol")"
  [ -n "$sub" ] || continue
  dir=".appdata/$sub"
  [ -d "$dir" ] || continue

  if grep -qx "$vol" <<<"$in_use"; then
    echo "  KEEP  $vol -- still mounted by a container"
    blocked=1
    continue
  fi
  # An empty destination is only suspicious if the source had something in
  # it. pihole_dnsmasq was empty to begin with, and copying nothing to
  # nowhere is a correct migration, not a failed one.
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    src_files=$(docker run --rm -v "${vol}:/v:ro" alpine:latest \
                  sh -c 'find /v -type f | wc -l' 2>/dev/null || echo 1)
    if [ "${src_files:-1}" -ne 0 ]; then
      echo "  KEEP  $vol -- $dir is empty but the volume is not"
      blocked=1
      continue
    fi
  fi
  eligible+=("$vol")
done

echo
if [ "${#eligible[@]}" -eq 0 ]; then
  echo "Nothing eligible."
  exit 0
fi
echo "Eligible for removal (${#eligible[@]}):"
printf '  %s\n' "${eligible[@]}"
echo

[ "$status_only" -eq 1 ] && exit 0

if [ "$offsite" -lt "$REQUIRED_CYCLES" ]; then
  echo "Refusing: only $offsite successful off-site cycle(s) since the migration, need $REQUIRED_CYCLES." >&2
  echo "These volumes are still the fallback. Re-run once the count is met." >&2
  exit 2
fi

if [ "$force" -ne 1 ]; then
  echo "Dry run. Re-run with --force to actually remove these."
  exit 0
fi

for vol in "${eligible[@]}"; do
  if docker volume rm "$vol" >/dev/null 2>&1; then
    echo "  removed $vol"
  else
    echo "  FAILED to remove $vol" >&2
    blocked=1
  fi
done
exit "$blocked"
