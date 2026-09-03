#!/usr/bin/env bash
# Bound the two log files nothing else rotates.
#
# Container stdout is capped by the json-file driver (10 MB x 3, the
# x-logging anchor), and Loki applies 720h retention. These two are
# written straight to a volume by the app and have no ceiling at all:
#
#   suricata eve.json    3.67 GB/day before tuning, ~1 GB/day after
#   traefik  access.log  ~0.17 GB/day
#
# Suricata's own type-disabling cannot finish the job: `flow` is 22.8% of
# eve.json and disabling it segfaults Suricata 8.0.6 (see the comment in
# docker-compose.ids.yml). So the file still needs a hard ceiling.
#
# Truncate rather than rotate-and-keep. Logs here are the instrument you
# triage with, not a record worth keeping -- Loki holds anything that
# mattered, and CrowdSec has already made its decisions from the alerts by
# the time a file is this large. Keeping eve.json.1 would just double the
# disk for data nobody reads.
#
# Both readers survive truncation. CrowdSec and suricata-exporter tail
# these files and reopen on inode/size change; the apps are signalled to
# reopen their own handle so a held file descriptor cannot leave a sparse
# file behind.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

EVE_MAX=${EVE_MAX:-$(( 1024 * 1024 * 1024 ))}      # 1 GB
ACCESS_MAX=${ACCESS_MAX:-$(( 512 * 1024 * 1024 ))} # 512 MB

# size_of <volume> <path-in-volume>
size_of() {
  docker run --rm -v "$1":/v:ro alpine:latest \
    stat -c %s "/v/$2" 2>/dev/null || echo 0
}

# truncate_in <volume> <path-in-volume>
truncate_in() {
  docker run --rm -v "$1":/v alpine:latest \
    sh -c ": > /v/$2"
}

trim() {
  local label="$1" volume="$2" file="$3" max="$4" container="$5" signal="$6"
  local size
  size=$(size_of "$volume" "$file")
  if [ "$size" -le "$max" ]; then
    printf '%s: %s MB, under the %s MB ceiling\n' \
      "$label" "$(( size / 1048576 ))" "$(( max / 1048576 ))"
    return 0
  fi

  printf '%s: %s MB exceeds %s MB, truncating\n' \
    "$label" "$(( size / 1048576 ))" "$(( max / 1048576 ))"
  truncate_in "$volume" "$file"

  # Make the writer reopen its handle. Without this an app holding the
  # old descriptor keeps writing at its previous offset, and the file
  # reports its old size again immediately as a sparse hole.
  if [ -n "$container" ]; then
    local id
    id=$(docker ps -q --filter "name=${container}" | head -1)
    if [ -n "$id" ]; then
      docker kill -s "$signal" "$id" >/dev/null
      printf '%s: sent SIG%s to %s so it reopens the file\n' "$label" "$signal" "$container"
    else
      printf '%s: WARNING container %s not running, could not signal\n' "$label" "$container"
    fi
  fi
}

trim "suricata eve.json" suricata_logs eve.json   "$EVE_MAX"    suricata HUP
trim "suricata stats.log" suricata_logs stats.log "$EVE_MAX"    suricata HUP
trim "traefik access.log" traefik_logs  access.log "$ACCESS_MAX" mediastack_traefik USR1
