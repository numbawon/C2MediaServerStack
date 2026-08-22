#!/usr/bin/env bash
# One-time setup: swarm init + the shared attachable network. Safe to
# re-run — every step checks current state first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
  echo "Initializing Swarm..."
  docker swarm init
else
  echo "Swarm already active, skipping init."
fi

if ! docker network inspect edge >/dev/null 2>&1; then
  echo "Creating attachable overlay network 'edge'..."
  docker network create --driver overlay --attachable edge
else
  echo "Network 'edge' already exists, skipping."
fi

echo "Bootstrap done. Next: scripts/init-secrets.sh, then deploy (see README.md)."
