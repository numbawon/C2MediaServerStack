#!/bin/sh
# Opens or closes ONE port-forward to the Minecraft host (C2-Swarm-02),
# tied to whether Crafty Controller actually has a server listening on it
# -- not a permanently-open port. Meant to be invoked over SSH via a
# forced-command key (see the authorized_keys entry this ships with), so
# a compromised Crafty container can run this script and nothing else on
# the router.
#
# Usage: minecraft-port-toggle.sh open|close <port> <protocol>
#
# Deliberately narrow: a fixed, explicit allow-list of (protocol, port)
# families below, one per game server type actually in use, and the
# destination is hardcoded to the one host Crafty runs on. This can never
# be used to forward some other port or protocol, or forward to some
# other machine, even if the forced-command restriction were ever
# bypassed some other way. Add a new game type by adding one line to
# is_allowed(), not by widening an existing range.
set -eu

MC_HOST="192.168.50.8"
LOG=/jffs/scripts/minecraft-port-toggle.log

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')	$*" >> "$LOG"
}

# Exit 0 (allowed) or 1 (not allowed). No output either way -- callers
# check $?, not stdout.
is_allowed() {
  _proto="$1"
  _port="$2"
  case "$_proto" in
    tcp)
      # Java: headroom for several concurrently-defined servers, per
      # docker-compose.crafty.yml's own published range.
      [ "$_port" -ge 25565 ] && [ "$_port" -le 25580 ] && return 0
      ;;
    udp)
      # Bedrock default, Hytale default. Exact-match only -- one server
      # of each type at a time, matching how these actually get run here.
      [ "$_port" = "19132" ] && return 0
      [ "$_port" = "5520" ] && return 0
      ;;
  esac
  return 1
}

ACTION="${1:-}"
PORT="${2:-}"
PROTO="${3:-}"

case "$ACTION" in
  open|close) ;;
  *) log "rejected: bad action '$ACTION'"; echo "usage: $0 open|close <port> <protocol>" >&2; exit 1 ;;
esac

case "$PORT" in
  ''|*[!0-9]*) log "rejected: non-numeric port '$PORT'"; echo "port must be numeric" >&2; exit 1 ;;
esac

case "$PROTO" in
  tcp|udp) ;;
  *) log "rejected: bad protocol '$PROTO'"; echo "protocol must be tcp or udp" >&2; exit 1 ;;
esac

if ! is_allowed "$PROTO" "$PORT"; then
  log "rejected: $PROTO/$PORT not on the allow-list"
  echo "$PROTO/$PORT is not on the allow-list" >&2
  exit 1
fi

RULE_ARGS="-p $PROTO --dport $PORT -j DNAT --to-destination $MC_HOST:$PORT"
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
