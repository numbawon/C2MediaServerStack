#!/usr/bin/env bash
# Restarts every container sharing the VPN container's network namespace
# when the tunnel's public IP changes, and notifies.
#
# WHY THIS IS NEEDED
#
# qbittorrent, sonarr, radarr and lazylibrarian all run with
# network_mode: service:vpn-client, so they have no network stack of their
# own. When gluetun reconnects -- server rotation, a rekey, a blip -- it
# builds a fresh tun0, and libtorrent stays bound to the interface that is
# now gone. qBittorrent then reports its OLD external address, sits at
# zero DHT nodes and transfers nothing, while still looking connected in
# its own UI. Nothing else notices, because the container is up, the mount
# is fine and there is no error in any log.
#
# Observed: exit IP moved 187.14.87.182 -> 187.13.212.16 and downloads
# stopped silently. A restart of qbittorrent fixed it instantly, going
# from "firewalled / 0 DHT nodes" to "connected / 292 nodes / 18 MB/s".
#
# WHY IT DOES NOT USE GLUETUN'S CONTROL SERVER
#
# gluetun exposes /v1/publicip/ip on :8000, which would be the obvious
# source, but every endpoint answers 401 on this version. Enabling that
# auth means restarting gluetun, which drops all four dependent apps --
# the exact outage this script exists to avoid. So the public IP is read
# by making one outbound request from inside the namespace, which is also
# a more honest test: it proves traffic actually leaves through the
# tunnel, rather than proving gluetun believes it should.
#
# Members are discovered from Docker rather than hardcoded, so adding a
# fifth app behind the VPN needs no change here.
set -uo pipefail

VPN_CONTAINER=${VPN_CONTAINER:-vpn-client}
STATE_DIR=${STATE_DIR:-/var/lib/mediastack}
STATE="$STATE_DIR/vpn-public-ip"
NTFY_TOPIC=${NTFY_TOPIC:-alerts}

log() { echo "[vpn-watchdog] $*"; }

# notify <title> <priority> <tags> <body>
# Publishes through the ntfy container on the edge overlay, reusing the
# same relay token alert-relay holds, so this needs no second credential.
notify() {
  local tk relay traefik
  relay=$(docker ps -qf name=mediastack_alert-relay | head -1)
  traefik=$(docker ps -qf name=mediastack_traefik | head -1)
  [ -n "$relay" ] && [ -n "$traefik" ] || { log "ntfy unavailable, not notifying"; return 0; }
  tk=$(docker exec "$relay" cat /run/secrets/ntfy_relay_token 2>/dev/null | tr -d '\n')
  [ -n "$tk" ] || { log "no relay token, not notifying"; return 0; }
  docker exec "$traefik" wget -qO- --timeout=15 \
    --header="Authorization: Bearer $tk" \
    --header="Title: $1" --header="Priority: $2" --header="Tags: $3" \
    --post-data="$4" "http://ntfy:80/$NTFY_TOPIC" >/dev/null 2>&1 \
      && log "notified: $1" || log "ntfy publish failed"
}

mkdir -p "$STATE_DIR" 2>/dev/null

docker inspect "$VPN_CONTAINER" >/dev/null 2>&1 || { log "$VPN_CONTAINER not present"; exit 0; }

# --- current public IP, as seen from inside the tunnel -------------------
current=""
for url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
  current=$(docker exec "$VPN_CONTAINER" sh -c "wget -qO- --timeout=8 '$url' 2>/dev/null" | tr -d '[:space:]')
  case "$current" in
    *.*.*.*) break ;;
    *) current="" ;;
  esac
done

if [ -z "$current" ]; then
  # No answer from any of three providers means the tunnel is down, not
  # that the IP changed. Restarting would not fix that and would just add
  # churn, so this reports and stops.
  log "could not determine public IP through $VPN_CONTAINER"
  notify "VPN tunnel unreachable" 4 "warning" \
    "No public IP could be read through $VPN_CONTAINER via three providers.
The tunnel is likely down. Nothing was restarted, because a restart does not fix a dead tunnel." 2>/dev/null
  exit 1
fi

previous=$(cat "$STATE" 2>/dev/null || echo "")

if [ "$current" = "$previous" ]; then
  exit 0
fi

printf '%s\n' "$current" > "$STATE"

# First run has nothing to compare against; record and stay quiet rather
# than announcing a change that did not happen.
if [ -z "$previous" ]; then
  log "first run, recorded $current"
  exit 0
fi

log "public IP changed: $previous -> $current"

# --- everything sharing the namespace ------------------------------------
vpn_id=$(docker inspect -f '{{.Id}}' "$VPN_CONTAINER")
members=$(docker ps --format '{{.Names}}' | while read -r c; do
  case "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null)" in
    container:"$vpn_id"*) echo "$c" ;;
  esac
done)

restarted=""; failed=""
for c in $members; do
  if docker restart "$c" >/dev/null 2>&1; then
    restarted="$restarted $c"; log "restarted $c"
  else
    failed="$failed $c"; log "FAILED to restart $c"
  fi
done

notify "VPN IP changed, dependent apps restarted" 3 "arrows_counterclockwise" \
"Tunnel moved $previous -> $current

Restarted:${restarted:- none}
${failed:+Failed:$failed}
These share the VPN network namespace and stay bound to the old tunnel otherwise, which looks like working but transfers nothing."
