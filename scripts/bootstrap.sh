#!/usr/bin/env bash
# One-time setup: swarm init + the shared attachable network. Safe to
# re-run -- every step checks current state first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
source .env
set +a

python3 scripts/validate-env.py

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
  if ! docker network inspect docker_gwbridge >/dev/null 2>&1; then
    echo "Creating docker_gwbridge with configured addressing..."
    docker network create \
      --driver bridge \
      --subnet "$COMMON_DOCKER_GWBRIDGE_SUBNET" \
      --gateway "$COMMON_DOCKER_GWBRIDGE_GATEWAY" \
      --opt com.docker.network.bridge.name=docker_gwbridge \
      docker_gwbridge
  fi
  echo "Initializing Swarm..."
  docker swarm init
else
  echo "Swarm already active, skipping init."
fi

actual_gw_subnet="$(docker network inspect docker_gwbridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
actual_gw_gateway="$(docker network inspect docker_gwbridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
if [ "$actual_gw_subnet" != "$COMMON_DOCKER_GWBRIDGE_SUBNET" ] ||
   [ "$actual_gw_gateway" != "$COMMON_DOCKER_GWBRIDGE_GATEWAY" ]; then
  echo "docker_gwbridge uses $actual_gw_subnet ($actual_gw_gateway)." >&2
  echo "Set COMMON_DOCKER_GWBRIDGE_SUBNET/GATEWAY to those values." >&2
  echo "Changing docker_gwbridge requires leaving Swarm; bootstrap will not do that." >&2
  exit 1
fi

if ! docker network inspect edge >/dev/null 2>&1; then
  echo "Creating attachable overlay network 'edge'..."
  docker network create \
    --driver overlay \
    --attachable \
    --subnet "$COMMON_EDGE_SUBNET" \
    edge
else
  actual_subnet="$(docker network inspect edge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  if [ "$actual_subnet" != "$COMMON_EDGE_SUBNET" ]; then
    echo "edge uses $actual_subnet, but COMMON_EDGE_SUBNET is $COMMON_EDGE_SUBNET" >&2
    echo "Set .env to the existing subnet or recreate edge while the stack is stopped." >&2
    exit 1
  fi
  echo "Network 'edge' already exists with expected subnet, skipping."
fi

python3 scripts/render-config.py

for path in "$COMMON_CONFIG/antivirus" "$COMMON_UPLOADS"; do
  if ! mkdir -p "$path"; then
    echo "Cannot create $path; create it as root, then set ownership to" >&2
    echo "$COMMON_PUID:$COMMON_PGID before deploying." >&2
    exit 1
  fi
  owner="$(stat -c '%u:%g' "$path")"
  if [ "$owner" != "$COMMON_PUID:$COMMON_PGID" ]; then
    echo "$path is owned by $owner; expected $COMMON_PUID:$COMMON_PGID." >&2
    echo "Fix ownership before deploying: sudo chown $COMMON_PUID:$COMMON_PGID '$path'" >&2
    exit 1
  fi
done

mkdir -p \
  "$COMMON_CONFIG/home-assistant" \
  "$COMMON_CONFIG/scrutiny/config" \
  "$COMMON_CONFIG/scrutiny/influxdb"

echo "Bootstrap done. Next: scripts/init-secrets.sh, then deploy (see README.md)."
