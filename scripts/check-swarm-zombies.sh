#!/usr/bin/env bash
# Finds Swarm services with more containers actually running, across all
# nodes, than the service's own desired replica count says there should
# be -- a real container Docker never cleaned up, invisible to `docker
# service ps` because Swarm itself has already written it off.
#
# Why this exists: found a Prowlarr container `docker ps` still showed as
# `Up 5 hours` on 2026-09-24, hours after `docker service ps` had already
# marked that exact task `Failed (non-zero exit 137)` and started a
# replacement -- both genuinely alive at once, sharing the same
# bind-mounted config/database. `docker service update --force` earlier
# that session is the likely trigger. Not wasted resources so much as a
# real risk: two live processes writing to the same SQLite file
# concurrently. Worth running any time a service's behavior looks
# inconsistent with what its config says, and always right after a
# `--force` update.
#
# Usage: ./scripts/check-swarm-zombies.sh
set -uo pipefail

LOCAL_HOST=$(hostname)
NODES=$(docker node ls --format '{{.Hostname}}')

found=0

while IFS=$'\t' read -r svc replicas; do
  desired="${replicas#*/}"
  # non-replicated (global) services scale with node count on purpose --
  # not what this is checking for.
  [[ "$replicas" == *"/"* ]] || continue

  actual=0
  for node in $NODES; do
    if [ "$node" = "$LOCAL_HOST" ]; then
      count=$(docker ps --format '{{.Names}}' | grep -c "^${svc}\.")
    else
      count=$(ssh -n -o ConnectTimeout=8 "$node" \
        "docker ps --format '{{.Names}}' | grep -c '^${svc}\.'" 2>/dev/null)
      count="${count:-0}"
    fi
    actual=$((actual + count))
  done

  if [ "$actual" -gt "$desired" ]; then
    found=1
    echo "ZOMBIE RISK: $svc -- desired $desired, actually running $actual across the cluster"
    echo "  Find it: for each node, docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}' | grep ${svc}"
    echo "  Then, once you've confirmed which container ID Swarm no longer"
    echo "  claims (compare against: docker service ps $svc):"
    echo "    docker stop <id> && docker rm <id>"
  fi
done < <(docker service ls --format '{{.Name}}\t{{.Replicas}}')

if [ "$found" -eq 0 ]; then
  echo "Clean -- every service's actual running container count matches what it should be."
fi

exit $found
