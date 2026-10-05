#!/usr/bin/env bash
# The roll call after a reboot. Proves the node actually came back, rather
# than assuming `systemctl reboot` returning means the cluster is whole.
#
# A worker node cannot ask the swarm "am I Ready?" (only managers can run
# `docker node ls`), so this checks what a worker can see for itself:
#   - the NFS media mount is live (Tdarr and anything else reading media)
#   - Docker's own swarm state is `active` with at least one reachable
#     manager and no error
#   - the standalone (non-swarm) containers listed in POSTBOOT_CONTAINERS
#     are running, since those are not swarm-scheduled and nothing else
#     will bring them back
# It retries for up to WAIT_SECONDS because the router may still be mid-
# reboot, then writes a Prometheus textfile metric either way. A node that
# cannot rejoin by itself (a lost swarm membership needs a join token only a
# manager has) turns into an alert instead of a silent hole in the cluster.
set -uo pipefail

CONF=/etc/mediastack-node.conf
WAIT_SECONDS=900
POSTBOOT_CONTAINERS=""      # space-separated, from CONF
NFS_MOUNT=""                # e.g. /mnt/media-nfs, from CONF; empty = skip
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

TEXTFILE_DIR=/var/lib/docker/volumes/node_exporter_textfile/_data
log() { echo "[postboot] $*"; }

nfs_ok()   { [ -z "$NFS_MOUNT" ] || timeout 20 ls "$NFS_MOUNT" >/dev/null 2>&1; }
swarm_ok() {
  local state mgrs err
  state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)
  mgrs=$(docker info --format '{{len .Swarm.RemoteManagers}}' 2>/dev/null)
  err=$(docker info --format '{{.Swarm.Error}}' 2>/dev/null)
  [ "$state" = "active" ] && [ "${mgrs:-0}" -ge 1 ] && [ -z "$err" ]
}
containers_ok() {
  local c ok=0
  for c in $POSTBOOT_CONTAINERS; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
      log "starting $c"; docker start "$c" >/dev/null 2>&1 || ok=1
    fi
  done
  return $ok
}

deadline=$(( $(date +%s) + WAIT_SECONDS ))
restarted_docker=0
result=0
while :; do
  if nfs_ok && swarm_ok && containers_ok; then result=1; break; fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  # Once, halfway through the wait, bounce Docker: a daemon that started
  # before the network was up can get stuck with a dead swarm connection.
  if [ "$restarted_docker" -eq 0 ] && [ "$(date +%s)" -ge $(( deadline - WAIT_SECONDS / 2 )) ] && ! swarm_ok; then
    log "swarm still not active, restarting docker once"
    systemctl restart docker; restarted_docker=1
  fi
  sleep 15
done

if [ "$result" -eq 1 ]; then log "node is back: nfs, swarm and containers all healthy"
else log "NODE DID NOT FULLY RECOVER: nfs_ok=$(nfs_ok && echo 1 || echo 0) swarm_ok=$(swarm_ok && echo 1 || echo 0)"; fi

if [ -d "$TEXTFILE_DIR" ]; then
  tmp="$TEXTFILE_DIR/.node_postboot.prom.$$"
  cat >"$tmp" <<M
# HELP mediastack_node_postboot_healthy 1 if the node rejoined the swarm and its services after the last boot.
# TYPE mediastack_node_postboot_healthy gauge
mediastack_node_postboot_healthy $result
# HELP mediastack_node_postboot_last_run_timestamp_seconds When the post-boot check last finished.
# TYPE mediastack_node_postboot_last_run_timestamp_seconds gauge
mediastack_node_postboot_last_run_timestamp_seconds $(date +%s)
M
  mv "$tmp" "$TEXTFILE_DIR/node_postboot.prom"
fi
[ "$result" -eq 1 ]
