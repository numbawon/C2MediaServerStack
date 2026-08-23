#!/usr/bin/env bash
# Creates every secret the stack needs. Run once before first deploy, and
# again any time you need to rotate one (drop the secret first: see below).
#
# - Swarm secrets (docker secret create) back the services in docker-stack.yml.
# - Local files under ./secrets/ (git-ignored, chmod 600) back the standalone
#   compose stacks (docker-compose.download.yml, docker-compose.plex.yml),
#   which can't use Swarm secrets since they're intentionally not swarm
#   services. See docker-stack.yml's header comment for why.
#
# Nothing here echoes a real secret value to stdout or a log.
set -euo pipefail

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
  echo "This node is not in an active Swarm. Run 'docker swarm init' first." >&2
  exit 1
fi

create_swarm_secret() {
  local name="$1" value="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    echo "Swarm secret '$name' already exists, skipping. (To rotate: docker secret rm $name, then redeploy the services using it, then re-run this script.)"
  else
    printf '%s' "$value" | docker secret create "$name" -
    echo "Created swarm secret: $name"
  fi
}

write_local_secret() {
  local file="$1" value="$2"
  mkdir -p secrets
  chmod 700 secrets
  printf '%s' "$value" > "secrets/$file"
  chmod 600 "secrets/$file"
  echo "Wrote secrets/$file"
}

random_password() {
  # openssl's base64 encoder wraps output at 64 chars; command substitution
  # only strips a *trailing* newline, not one embedded mid-string, so a
  # value long enough to wrap silently gets a newline baked into it. Strip
  # all newlines explicitly rather than relying on the byte count staying
  # under the wrap threshold.
  openssl rand -base64 "${1:-24}" | tr -d '\n'
}

echo "== Auto-generated secrets (random, no input needed) =="
create_swarm_secret postgres_password        "$(random_password)"
create_swarm_secret redis_password           "$(random_password)"
create_swarm_secret grafana_admin_password   "$(random_password)"
create_swarm_secret authentik_secret_key     "$(random_password 60)"

echo
echo "== Secrets that need a real value from you =="

read -rsp "Cloudflare Tunnel token (from 'cloudflared tunnel create' / Zero Trust dashboard): " cf_token
echo
create_swarm_secret cloudflare_tunnel_token "$cf_token"
unset cf_token

read -rsp "NordVPN access token (from the NordVPN dashboard): " nord_token
echo
write_local_secret nordvpn_token.txt "$nord_token"
unset nord_token

echo "Plex claim tokens expire ~4 minutes after being issued at https://plex.tv/claim"
read -rp "Open that URL, log in, and paste the claim token here: " plex_claim
write_local_secret plex_claim.txt "$plex_claim"
unset plex_claim

echo
echo "Done. Swarm secrets: postgres_password, redis_password, grafana_admin_password,"
echo "authentik_secret_key, cloudflare_tunnel_token."
echo "Local files: secrets/nordvpn_token.txt, secrets/plex_claim.txt"
