#!/usr/bin/env bash
# Force-tests every indexer in Prowlarr and every Servarr app it feeds
# (Radarr, Sonarr, Lidarr), and reports each app's own indexer health
# afterward.
#
# Why this exists: Sonarr, Radarr, Lidarr and Prowlarr each keep their own
# independent per-indexer failure tracking. Fixing a shared root cause
# (the proxy, DNS, whatever) only clears the app you directly touched --
# the others silently keep refusing every indexer with "unavailable due
# to failures for more than 6 hours" until THEY see a fresh success of
# their own. Confirmed the hard way 2026-09-24: fixing Prowlarr's proxy
# auth did nothing for Sonarr or Radarr, both of which had independently
# locked out every indexer over the same outage window, and neither
# recovered on a plain restart -- only an actual successful test call
# cleared it. Run this after fixing anything that touches indexer
# reachability (proxy, DNS, network), not just the app you fixed.
#
# LazyLibrarian and Mylar3 are also Prowlarr-synced but are not part of
# the Servarr family (different codebase entirely), so they don't share
# this REST API shape and aren't covered here.
#
# Usage: ./scripts/arr/test-all-indexers.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# name:container-name-filter:port:urlbase:api-version:health-path
APPS=(
  "prowlarr:mediastack_prowlarr:9696::v1:/api/v1/health"
  "radarr:mediastack_radarr:7878:/radarr:v3:/radarr/api/v3/health"
  "sonarr:mediastack_sonarr:8989:/sonarr:v3:/sonarr/api/v3/health"
  "lidarr:mediastack_lidarr:8686::v3:/api/v3/health"
)

overall_fail=0

for entry in "${APPS[@]}"; do
  IFS=: read -r name filter port base apiver healthpath <<<"$entry"
  echo "=== $name ==="

  cid=$(docker ps -q -f "name=${filter}" | head -1)
  if [ -z "$cid" ]; then
    echo "  container not found/running, skipping"
    echo
    continue
  fi

  apikey=$(docker exec "$cid" grep -i apikey /config/config.xml | grep -oE '[a-f0-9]{32}')
  if [ -z "$apikey" ]; then
    echo "  could not read API key, skipping"
    echo
    continue
  fi

  indexer_path="${base}/api/${apiver}/indexer"
  test_path="${base}/api/${apiver}/indexer/test"

  ids=$(docker exec "$cid" curl -s -H "X-Api-Key: $apikey" "http://localhost:${port}${indexer_path}" \
    | python3 -c "import json,sys
try:
    print(' '.join(str(i['id']) for i in json.load(sys.stdin)))
except Exception:
    pass" 2>/dev/null)

  if [ -z "$ids" ]; then
    echo "  no indexers configured (or API call failed)"
  fi

  pass=0
  fail=0
  for id in $ids; do
    idx_file="$TMPDIR/${name}_idx_${id}.json"
    docker exec "$cid" curl -s "http://localhost:${port}${indexer_path}/${id}" \
      -H "X-Api-Key: $apikey" > "$idx_file"
    idx_name=$(python3 -c "import json; print(json.load(open('$idx_file')).get('name','?'))" 2>/dev/null)

    code=$(docker exec -i "$cid" sh -c \
      "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Api-Key: $apikey' -H 'Content-Type: application/json' --data @/dev/stdin 'http://localhost:${port}${test_path}'" \
      < "$idx_file")

    if [ "$code" = "200" ]; then
      pass=$((pass + 1))
      echo "  OK   $idx_name"
    else
      fail=$((fail + 1))
      overall_fail=$((overall_fail + 1))
      echo "  FAIL $idx_name (HTTP $code)"
    fi
  done
  echo "  -> $pass passed, $fail failed"

  echo "  health after testing:"
  docker exec "$cid" curl -s -H "X-Api-Key: $apikey" "http://localhost:${port}${healthpath}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d:
    print('    clean')
else:
    for w in d:
        print(f\"    [{w.get('type')}] {w.get('source')}: {w.get('message')}\")
" 2>/dev/null
  echo
done

if [ "$overall_fail" -gt 0 ]; then
  echo "Done -- $overall_fail individual indexer test(s) failed. A handful of"
  echo "dead upstream trackers failing is normal and not worth chasing; if"
  echo "whole apps show every indexer failing, that's the real signal."
else
  echo "Done -- every indexer in every app passed."
fi
