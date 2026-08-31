#!/usr/bin/env bash
# `docker stack deploy` does NOT read .env automatically the way
# `docker compose` does -- it only substitutes from the current shell's
# exported environment. This wraps that so COMMON_* vars from .env always
# make it into the stack. Usage:
#   ./scripts/deploy.sh stack       # docker stack deploy (core swarm stack)
#   ./scripts/deploy.sh download    # docker compose -f docker-compose.download.yml up -d
#   ./scripts/deploy.sh plex        # docker compose -f docker-compose.plex.yml up -d
#   ./scripts/deploy.sh dns         # docker compose -f docker-compose.dns.yml up -d (Pi-hole)
#   ./scripts/deploy.sh ai          # docker compose -f docker-compose.ai.yml up -d (Ollama + Open WebUI)
#   ./scripts/deploy.sh tdarr       # docker compose -f docker-compose.tdarr.yml up -d
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
source .env
set +a

case "${1:-}" in
  stack)
    docker stack deploy -c docker-stack.yml mediastack
    ;;
  download)
    docker compose -f docker-compose.download.yml up -d
    ;;
  plex)
    docker compose -f docker-compose.plex.yml up -d
    ;;
  dns)
    docker compose -f docker-compose.dns.yml up -d
    ;;
  ai)
    docker compose -f docker-compose.ai.yml up -d
    ;;
  tdarr)
    docker compose -f docker-compose.tdarr.yml up -d
    ;;
  *)
    echo "Usage: $0 {stack|download|plex|dns|ai|tdarr}" >&2
    exit 1
    ;;
esac
