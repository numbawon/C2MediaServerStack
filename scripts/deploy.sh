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
#   ./scripts/deploy.sh audiomuse   # docker compose -f docker-compose.audiomuse.yml up -d (AudioMuse-AI)
#   ./scripts/deploy.sh ids         # docker compose -f docker-compose.ids.yml up -d (Suricata + CrowdSec)
#   ./scripts/deploy.sh i2p         # docker compose -f docker-compose.i2p.yml up -d (I2P router)
#   ./scripts/deploy.sh configured  # deploy COMMON_DEPLOYMENT_COMPONENTS in order
#   ./scripts/deploy.sh recovery    # deploy COMMON_RECOVERY_COMPONENTS in order
#   ./scripts/deploy.sh home        # Home Assistant + Scrutiny
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
source .env
set +a

python3 scripts/validate-env.py

# Materialize deployment-specific configs kept out of Git. Safe and
# idempotent; templates are the source of truth.
deploy_component() {
case "$1" in
  stack)
    ./scripts/swarm-preflight.sh
    python3 scripts/render-config.py
    # Built directly under the registry-qualified tag so it matches
    # docker-stack.yml's `image:` exactly -- Docker treats
    # ${COMMON_LAN_IP}:5000/x and localhost:5000/x as different registries
    # even when both resolve to the same server, so build/push/deploy all
    # have to agree on the one string.
    docker build --quiet \
      --tag "${COMMON_LAN_IP}:5000/c2mediaserverstack/pinepods:nightly20260911-upstream-09c3dcd" \
      --file pinepods/Dockerfile pinepods >/dev/null
    docker build --quiet \
      --tag "${COMMON_LAN_IP}:5000/c2mediaserverstack/zork:1" \
      --file zork/Dockerfile zork >/dev/null
    docker stack deploy -c docker-stack.yml mediastack
    # Push after deploy, not before: on a from-scratch bootstrap the
    # registry service does not exist until this same deploy creates it.
    # Non-fatal, same reasoning as roll-unpinned.sh's pull failures --
    # every other node still runs whatever it already had, this only
    # means a node with none of that image yet cannot schedule it until
    # the next successful push.
    for i in $(seq 1 10); do
      curl -sf "http://${COMMON_LAN_IP}:5000/v2/" >/dev/null 2>&1 && break
      sleep 1
    done
    docker push "${COMMON_LAN_IP}:5000/c2mediaserverstack/pinepods:nightly20260911-upstream-09c3dcd" \
      || echo "WARNING: could not push pinepods to the registry, nodes without a local copy cannot run it yet" >&2
    docker push "${COMMON_LAN_IP}:5000/c2mediaserverstack/zork:1" \
      || echo "WARNING: could not push zork to the registry, nodes without a local copy cannot run it yet" >&2
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
  audiomuse)
    docker compose -f docker-compose.audiomuse.yml up -d
    ;;
  hermes)
    docker compose -f docker-compose.hermes.yml up -d
    ;;
  ids)
    docker compose -f docker-compose.ids.yml up -d
    ;;
  i2p)
    docker compose -f docker-compose.i2p.yml up -d
    ;;
  home)
    python3 scripts/render-config.py
    docker compose -f docker-compose.home.yml up -d
    ;;
  *)
    echo "Unknown deployment component: $1" >&2
    exit 1
    ;;
esac
}

case "${1:-}" in
  configured)
    for component in ${COMMON_DEPLOYMENT_COMPONENTS:-stack}; do
      deploy_component "$component"
    done
    ;;
  recovery)
    # Unattended (run by mediastack-recovery.service after a reboot), so one
    # component failing must not stop the rest from being tried. A stray
    # container name conflict on `download` silently left `ids` and `home`
    # never re-applied for 21 hours after a reboot -- `set -e` on the loop
    # itself turned one bad recreate into every component after it never
    # running. Still exits non-zero if anything failed, so the systemd unit
    # shows failed and `systemctl status mediastack-recovery.service` says
    # which component, but every component gets a chance regardless.
    failed=()
    for component in ${COMMON_RECOVERY_COMPONENTS-dns download plex ids}; do
      echo "== recovery: $component =="
      if ! deploy_component "$component"; then
        echo "FAILED: $component" >&2
        failed+=("$component")
      fi
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "recovery: failed components: ${failed[*]}" >&2
      exit 1
    fi
    ;;
  stack|download|plex|dns|ai|tdarr|audiomuse|hermes|ids|i2p|home)
    deploy_component "$1"
    ;;
  *)
    echo "Usage: $0 {configured|recovery|stack|download|plex|dns|ai|tdarr|audiomuse|hermes|ids|i2p|home}" >&2
    exit 1
    ;;
esac
