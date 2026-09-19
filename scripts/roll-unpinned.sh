#!/usr/bin/env bash
# Pulls and redeploys every currently-running service EXCEPT the ones
# below, reporting/applying only the ones with a genuinely newer digest
# upstream. Manual, on-demand only -- nothing here runs on a schedule.
# copilot-instructions.md is explicit that automatic image mutation is not
# to be added (Diun stays notification-only); this script does not change
# that, it just removes the "type each `docker pull` / `service update` by
# hand" tedium of a decision a human still has to run.
#
# Usage:
#   ./scripts/roll-unpinned.sh              # pull + redeploy anything outdated
#   ./scripts/roll-unpinned.sh -WhatIf       # report only, change nothing
#   ./scripts/roll-unpinned.sh -DryRun       # same as -WhatIf
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -WhatIf|--whatif|-DryRun|--dry-run) DRY_RUN=true ;;
    *)
      echo "Usage: $0 [-WhatIf|-DryRun]" >&2
      exit 1
      ;;
  esac
done

set -a
source .env
set +a

# Deliberately pinned / data-sensitive, excluded even when their tag
# happens to float. Traefik and Authentik require the manual release-note
# review in .claude/skills/is-it-new/SKILL.md; traefik-manager can rewrite
# Traefik's own auth; the rest are the stack's databases/caches. Everything
# NOT listed here is judged purely on whether a pull actually finds a newer
# digest, regardless of whether its tag looks like :latest or an exact pin --
# an exact pin with nothing new upstream is a no-op either way.
#
# mediastack_pinepods is excluded for a different reason: its image is
# built locally (see `stack` in deploy.sh), never pulled from a registry,
# so `docker pull` against it always fails.
SWARM_EXCLUDE=(
  mediastack_traefik
  mediastack_authentik-server
  mediastack_authentik-worker
  mediastack_traefik-manager
  mediastack_postgres
  mediastack_redis
  mediastack_immich-postgres
  mediastack_immich-redis
  mediastack_pinepods-postgres
  mediastack_pinepods-valkey
  mediastack_pinepods
)
STANDALONE_EXCLUDE=(
  audiomuse-postgres
)

# Standalone compose files this repo knows about; mirrors deploy.sh's list.
COMPOSE_FILES=(download plex dns ai tdarr audiomuse hermes ids i2p home)

is_excluded() {
  local name="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$name" ] && return 0
  done
  return 1
}

updated=0
would_update=0

echo "== Swarm services =="
for svc in $(docker service ls --format '{{.Name}}'); do
  if is_excluded "$svc" "${SWARM_EXCLUDE[@]}"; then
    continue
  fi
  image=$(docker service inspect "$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/@sha256.*//')
  if ! pull_out=$(docker pull "$image" 2>&1 | tail -1); then
    echo "SKIP (pull failed): $svc  ($image)"
    continue
  fi
  if echo "$pull_out" | grep -q "Downloaded newer image"; then
    if $DRY_RUN; then
      echo "WOULD UPDATE: $svc  ($image)"
      would_update=$((would_update + 1))
    else
      echo "UPDATING: $svc  ($image)"
      docker service update --image "$image" --with-registry-auth "$svc" >/dev/null
      updated=$((updated + 1))
    fi
  fi
done

echo "== Standalone compose =="
for f in "${COMPOSE_FILES[@]}"; do
  file="docker-compose.$f.yml"
  [ -f "$file" ] || continue
  for svc in $(docker compose -f "$file" config --services 2>/dev/null); do
    if is_excluded "$svc" "${STANDALONE_EXCLUDE[@]}"; then
      continue
    fi
    container_id=$(docker compose -f "$file" ps -q "$svc" 2>/dev/null || true)
    [ -z "$container_id" ] && continue  # not running, skip
    image=$(docker inspect "$container_id" --format '{{.Config.Image}}')
    if ! pull_out=$(docker pull "$image" 2>&1 | tail -1); then
      echo "SKIP (pull failed): $svc  ($image)  [$file]"
      continue
    fi
    if echo "$pull_out" | grep -q "Downloaded newer image"; then
      if $DRY_RUN; then
        echo "WOULD UPDATE: $svc  ($image)  [$file]"
        would_update=$((would_update + 1))
      else
        echo "UPDATING: $svc  ($image)  [$file]"
        docker compose -f "$file" up -d "$svc" >/dev/null
        updated=$((updated + 1))
      fi
    fi
  done
done

echo "=================================="
if $DRY_RUN; then
  echo "Would update: $would_update (nothing changed, -WhatIf/-DryRun)"
else
  echo "Updated: $updated"
fi
