#!/usr/bin/env bash
# Generates prometheus/targets/*.json from .env.
#
# Prometheus does NO environment substitution in its config file, so the
# blackbox probe targets cannot be written as ${COMMON_DOMAIN} inline.
# Generating them keeps the real domain and LAN IP out of version control
# (targets/*.json is git-ignored) while prometheus.yml stays tracked and
# generic.
#
# Run after changing COMMON_DOMAIN or COMMON_LAN_IP, then:
#   docker service update --force mediastack_prometheus
# Prometheus re-reads file_sd targets on its own, but a scrape-config
# change still needs the restart.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
# shellcheck disable=SC1091
source .env
set +a

OUT="prometheus/targets"
mkdir -p "$OUT"

# Gated apps sit behind Authentik forward-auth and answer 302 to a login
# page. That is the correct healthy response, not an error.
cat > "$OUT/blackbox-gated.json" <<JSON
[
  {
    "targets": [
      "https://homer.${COMMON_DOMAIN}/",
      "https://seerr.${COMMON_DOMAIN}/",
      "https://grafana.${COMMON_DOMAIN}/",
      "https://prowlarr.${COMMON_DOMAIN}/",
      "https://portainer.${COMMON_DOMAIN}/",
      "https://cleanuparr.${COMMON_DOMAIN}/"
    ],
    "labels": { "tier": "gated" }
  }
]
JSON

# Ungated apps: native OIDC or their own auth, no forward-auth gate.
cat > "$OUT/blackbox-open.json" <<JSON
[
  {
    "targets": [
      "https://ntfy.${COMMON_DOMAIN}/",
      "https://immich.${COMMON_DOMAIN}/",
      "https://audiobookshelf.${COMMON_DOMAIN}/"
    ],
    "labels": { "tier": "open" }
  }
]
JSON

# Pi-hole is the resolver containers should be using; the router is the
# one that broke on 2026-08-27. Probing both says which is at fault.
ROUTER="${COMMON_LAN_SUBNET%%/*}"; ROUTER="${ROUTER%.*}.1"
# Origin certificate probe. One target is enough: Traefik serves the same
# wildcard for every hostname, so this measures the cert all of them use.
# The value is used as the `hostname` parameter (Host header + TLS SNI),
# not as the URL -- the URL is a constant pointing at Traefik directly.
cat > "$OUT/blackbox-origin.json" <<JSON
[
  {
    "targets": [
      "grafana.${COMMON_DOMAIN}"
    ],
    "labels": { "tier": "origin" }
  }
]
JSON
cat > "$OUT/blackbox-dns.json" <<JSON
[
  { "targets": ["${COMMON_LAN_IP}"], "labels": { "resolver": "pihole" } },
  { "targets": ["${ROUTER}"], "labels": { "resolver": "router" } }
]
JSON

# Only Pi-hole: the router does not block, so probing it here would
# fail by design and produce a permanently-firing alert.
cat > "$OUT/blackbox-dns-blocked.json" <<JSON
[
  { "targets": ["${COMMON_LAN_IP}"], "labels": { "resolver": "pihole" } }
]
JSON

cat > "$OUT/blackbox-dns-aaaa.json" <<JSON
[
  { "targets": ["${COMMON_LAN_IP}"], "labels": { "resolver": "pihole" } },
  { "targets": ["${ROUTER}"], "labels": { "resolver": "router" } }
]
JSON

echo "Wrote:"
for f in "$OUT"/*.json; do echo "  $f"; done
