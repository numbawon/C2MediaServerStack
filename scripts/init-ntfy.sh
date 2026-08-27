#!/usr/bin/env bash
# One-time ntfy bootstrap. Run AFTER the stack is deployed and ntfy has
# started, because ntfy creates its user database on first boot and
# accounts cannot be added before that exists.
#
# This is why it cannot live in init-secrets.sh: everything there runs
# before anything is deployed.
#
# Creates two least-privilege accounts rather than one shared admin:
#   relay -- write-only on the topic. Its token becomes the
#            ntfy_relay_token Swarm secret that alert-relay publishes
#            with. Leaking it lets someone send you a fake alert; it
#            does not let them read your alert history.
#   phone -- read-only on the topic. Its token goes in the ntfy Android
#            app. Leaking it lets someone read alerts; it does not let
#            them forge one.
#
# Neither is an admin, so neither can create users or grant access.
# Verified enforced: anonymous read, anonymous publish, and a publish
# attempt with the phone token all return 403.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOPIC="${NTFY_TOPIC:-alerts}"
RELAY_SERVICE="mediastack_alert-relay"

C=$(docker ps -qf "name=mediastack_ntfy" | head -1)
if [ -z "$C" ]; then
  echo "No running ntfy container found. Deploy the stack first:" >&2
  echo "  ./scripts/deploy.sh stack" >&2
  exit 1
fi
echo "Using ntfy container: $C"

random_password() { head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32; }

# `ntfy user add` prompts for a password twice, but it reads from plain
# stdin rather than requiring a TTY, so piping works and this stays
# non-interactive. The passwords are deliberately random and thrown
# away: tokens are what actually authenticate, and neither account is
# ever meant to be logged into.
add_user() {
  local user="$1" perm="$2" pw
  if docker exec "$C" ntfy user list 2>/dev/null | grep -q "^user ${user} "; then
    echo "user '${user}' already exists, leaving it alone"
  else
    pw=$(random_password)
    printf '%s\n%s\n' "$pw" "$pw" | docker exec -i "$C" ntfy user add "$user" >/dev/null
    echo "created user '${user}'"
  fi
  docker exec "$C" ntfy access "$user" "$TOPIC" "$perm" >/dev/null
  echo "  granted ${perm} on topic '${TOPIC}'"
}

# `ntfy token add` prints e.g.
#   tk_abc123... (label), expires never, accessed from ...
issue_token() {
  docker exec "$C" ntfy token add --label="$2" "$1" 2>&1 \
    | grep -oE 'tk_[A-Za-z0-9]+' | head -1
}

add_user relay write-only
add_user phone read-only

relay_token=$(issue_token relay alert-relay)
phone_token=$(issue_token phone android-app)
for t in "$relay_token" "$phone_token"; do
  if [ -z "$t" ]; then
    echo "Could not parse a token out of 'ntfy token add'." >&2
    exit 1
  fi
done
echo "issued both tokens"

# Swarm secrets are immutable, so replacing one means removing it first
# -- and Docker refuses to remove a secret still attached to a running
# service. Detach it from alert-relay before the swap. The service keeps
# running throughout; the redeploy at the end reattaches the new one.
if docker secret inspect ntfy_relay_token >/dev/null 2>&1; then
  if docker service inspect "$RELAY_SERVICE" >/dev/null 2>&1; then
    echo "Detaching the old secret from ${RELAY_SERVICE}..."
    docker service update --secret-rm ntfy_relay_token "$RELAY_SERVICE" >/dev/null
  fi
  docker secret rm ntfy_relay_token >/dev/null
fi
printf '%s' "$relay_token" | docker secret create ntfy_relay_token - >/dev/null
echo "Swarm secret ntfy_relay_token now holds the live relay token"

# The phone token has to be readable by a human to get it into the app.
# secrets/ is git-ignored; keep it that way.
mkdir -p secrets
printf '%s\n' "$phone_token" > secrets/ntfy_phone_token.txt
chmod 600 secrets/ntfy_phone_token.txt

cat <<EOF

--------------------------------------------------------------------
Done. Redeploy so alert-relay picks up the new secret:

  ./scripts/deploy.sh stack

Then set up the Android app:

  server: https://ntfy.<your-domain>
  topic:  ${TOPIC}
  token:  (in secrets/ntfy_phone_token.txt)

and under Settings -> Advanced -> Custom headers, the Cloudflare
Access service token from the Zero Trust dashboard:

  CF-Access-Client-Id:     <...>
  CF-Access-Client-Secret: <...>

Test the whole path end to end by injecting an alert at Alertmanager
(not by publishing to ntfy directly, which would skip the relay):

  docker exec \$(docker ps -qf name=mediastack_prometheus) sh -c \\
    'wget -qO- --post-data='"'"'[{"labels":{"alertname":"Test","severity":"critical"},"annotations":{"summary":"hello"}}]'"'"' \\
     --header="Content-Type: application/json" http://alertmanager:9093/api/v2/alerts'
--------------------------------------------------------------------
EOF
