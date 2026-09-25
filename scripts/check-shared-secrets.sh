#!/usr/bin/env bash
# Compares (by checksum, never printing a value) the pairs of credentials
# in this stack that are supposed to hold the same value but come from
# two genuinely independent sources with nothing enforcing agreement.
#
# Why this exists: vpn-client (docker-compose.download.yml, a plain
# `docker compose` deployment) sources its proxy credentials from a
# file-backed Compose secret. Everything else that needs the same
# credentials (currently just byparr) sources them from a real Swarm
# secret. Same intent, two unrelated storage mechanisms, and they
# silently drifted apart at some point with nothing to catch it --
# confirmed the hard way 2026-09-24, when it took an evening to work out
# why Prowlarr and ByParr were both getting rejected by the router's own
# proxy despite every individual piece looking correctly configured.
#
# Add a new pair below any time something else grows this same shape
# (one file-backed copy, one Swarm-secret copy, meant to match).
#
# Usage: ./scripts/check-shared-secrets.sh
set -uo pipefail

LOCAL_HOST=$(hostname)

# label : container holding the file-backed copy : path inside it
#       : Swarm service holding the Swarm-secret copy : path inside it
PAIRS=(
  "httpproxy_user|vpn-client|/run/secrets/httpproxy_user|mediastack_byparr|/run/secrets/httpproxy_user"
  "httpproxy_password|vpn-client|/run/secrets/httpproxy_password|mediastack_byparr|/run/secrets/httpproxy_password_v2"
)

# Reads a file's checksum from a container by name, wherever it's
# actually running. Standalone containers (like vpn-client) are always
# local. Swarm services (mediastack_*) can float to any node with no
# placement constraint -- found the hard way this script needs to look,
# not assume this runs on the manager node. Prints a sha256 or nothing
# on failure.
checksum_in_container() {
  local name="$1" path="$2"
  local cid
  cid=$(docker ps -q -f "name=${name}" | head -1)
  if [ -n "$cid" ]; then
    docker exec "$cid" sh -c "sha256sum '$path' 2>/dev/null | cut -d' ' -f1"
    return
  fi

  # Not local. If it looks like a Swarm service, find its actual node.
  if [[ "$name" == mediastack_* ]]; then
    local node
    node=$(docker service ps "$name" --filter desired-state=running \
      --format '{{.Node}}' 2>/dev/null | head -1)
    if [ -n "$node" ] && [ "$node" != "$LOCAL_HOST" ]; then
      ssh -n -o ConnectTimeout=8 "$node" \
        "docker exec \$(docker ps -q -f name=${name} | head -1) sh -c \"sha256sum '$path' 2>/dev/null | cut -d' ' -f1\"" \
        2>/dev/null
    fi
  fi
}

fail=0

for pair in "${PAIRS[@]}"; do
  IFS='|' read -r label c1 p1 c2 p2 <<<"$pair"

  h1=$(checksum_in_container "$c1" "$p1")
  h2=$(checksum_in_container "$c2" "$p2")

  if [ -z "$h1" ] || [ -z "$h2" ]; then
    echo "SKIP $label: couldn't read one or both files ($c1:$p1, $c2:$p2 -- is either container down?)"
    continue
  fi

  if [ "$h1" = "$h2" ]; then
    echo "OK   $label: matches"
  else
    echo "DRIFT $label: $c1's copy and $c2's copy do NOT match"
    echo "      fix: create a new versioned Swarm secret from $c1's actual"
    echo "      value, repoint every Swarm-side consumer at it, redeploy."
    echo "      See the Learned lessons doc in Obsidian for the full recipe."
    fail=1
  fi
done

exit $fail
