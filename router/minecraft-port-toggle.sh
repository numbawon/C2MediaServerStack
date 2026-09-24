#!/bin/sh
# Opens or closes ONE port-forward to the Minecraft host (C2-Swarm-02),
# tied to whether Crafty Controller actually has a server listening on it
# -- not a permanently-open port. Meant to be invoked over SSH via a
# forced-command key (see the authorized_keys entry this ships with), so
# a compromised Crafty container can run this script and nothing else on
# the router.
#
# Usage: minecraft-port-toggle.sh open|close <port>
#
# Deliberately narrow: only ports in the range docker-compose.crafty.yml
# actually publishes (25565-25580) are accepted, and the destination is
# hardcoded to the one host Crafty runs on. This can never be used to
# forward some other port, or forward to some other machine, even if the
# forced-command restriction were ever bypassed some other way.
set -eu

MC_HOST="192.168.50.8"
MIN_PORT=25565
MAX_PORT=25580
LOG=/jffs/scripts/minecraft-port-toggle.log

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')	$*" >> "$LOG"
}

ACTION="${1:-}"
PORT="${2:-}"

case "$ACTION" in
  open|close) ;;
  *) log "rejected: bad action '$ACTION'"; echo "usage: $0 open|close <port>" >&2; exit 1 ;;
esac

case "$PORT" in
  ''|*[!0-9]*) log "rejected: non-numeric port '$PORT'"; echo "port must be numeric" >&2; exit 1 ;;
esac

if [ "$PORT" -lt "$MIN_PORT" ] || [ "$PORT" -gt "$MAX_PORT" ]; then
  log "rejected: port $PORT outside $MIN_PORT-$MAX_PORT"
  echo "port must be $MIN_PORT-$MAX_PORT" >&2
  exit 1
fi

RULE_ARGS="-p tcp --dport $PORT -j DNAT --to-destination $MC_HOST:$PORT"
EXISTS=0
# shellcheck disable=SC2086
iptables -t nat -C VSERVER $RULE_ARGS 2>/dev/null && EXISTS=1

if [ "$ACTION" = "open" ]; then
  if [ "$EXISTS" = "1" ]; then
    log "open $PORT: already open, no-op"
  else
    # shellcheck disable=SC2086
    iptables -t nat -I VSERVER $RULE_ARGS
    log "open $PORT: rule added"
  fi
else
  if [ "$EXISTS" = "1" ]; then
    # shellcheck disable=SC2086
    iptables -t nat -D VSERVER $RULE_ARGS
    log "close $PORT: rule removed"
  else
    log "close $PORT: already closed, no-op"
  fi
fi
