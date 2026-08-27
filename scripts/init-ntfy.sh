#!/usr/bin/env bash
# One-time ntfy bootstrap. Run AFTER the stack is deployed and ntfy has
# started, because ntfy has to create its user database on first boot
# before accounts can be added to it.
#
# This cannot live in init-secrets.sh for that reason: everything there
# runs before anything is deployed.
#
# Creates two least-privilege accounts rather than one shared admin:
#   relay -- write-only on the alerts topic. Its token becomes the
#            ntfy_relay_token Swarm secret that alert-relay publishes
#            with. A leak of this token lets someone send you a fake
#            alert; it does not let them read your alert history.
#   phone -- read-only on the alerts topic. Its token goes in the ntfy
#            Android app. A leak lets someone read alerts; it does not
#            let them forge one.
#
# Neither is an admin, so neither can create users or grant access.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOPIC="${NTFY_TOPIC:-alerts}"

C=$(docker ps -qf "name=ntfy" | head -1)
if [ -z "$C" ]; then
  echo "No running ntfy container found. Deploy the stack first:" >&2
  echo "  ./scripts/deploy.sh stack" >&2
  exit 1
fi
echo "Using ntfy container: $C"

# `ntfy user add` reads the password from a terminal, so this needs -it
# and cannot be made fully non-interactive. It is a one-time step.
add_user() {
  local user="$1" perm="$2"
  if docker exec "$C" ntfy user list 2>/dev/null | grep -q "^user ${user}\b"; then
    echo "user '${user}' already exists, leaving it alone"
  else
    echo
    echo "Creating ntfy user '${user}' -- you will be prompted for a password."
    echo "You do not need to remember it: the token issued below is what"
    echo "actually gets used. Any long random string is fine."
    docker exec -it "$C" ntfy user add "$user"
  fi
  docker exec "$C" ntfy access "$user" "$TOPIC" "$perm"
  echo "granted ${user}: ${perm} on topic '${TOPIC}'"
}

# Extract the token out of `ntfy token add` output, which looks like:
#   tk_abc123... (label), expires never, accessed from ...
issue_token() {
  local user="$1" label="$2"
  docker exec "$C" ntfy token add --label="$label" "$user" 2>/dev/null \
    | grep -oE 'tk_[A-Za-z0-9]+' | head -1
}

add_user relay write-only
add_user phone read-only

echo
relay_token=$(issue_token relay alert-relay)
if [ -z "$relay_token" ]; then
  echo "Could not parse a token out of 'ntfy token add' for relay." >&2
  exit 1
fi

# Recreate rather than update: Swarm secrets are immutable, so an
# existing one has to be removed first. It is only in use by alert-relay.
if docker secret inspect ntfy_relay_token >/dev/null 2>&1; then
  echo "Removing the previous ntfy_relay_token secret."
  echo "NOTE: alert-relay keeps running with the OLD token until you"
  echo "      redeploy the stack, so alerts are not lost in between."
  docker secret rm ntfy_relay_token >/dev/null
fi
printf '%s' "$relay_token" | docker secret create ntfy_relay_token - >/dev/null
echo "Created Swarm secret: ntfy_relay_token"

phone_token=$(issue_token phone android-app)

cat <<EOF

--------------------------------------------------------------------
Done.

Put this token in the ntfy Android app
(Settings -> Manage users, or per-server under the subscription):

  server: https://ntfy.<your-domain>
  topic:  ${TOPIC}
  token:  ${phone_token}

You ALSO need the Cloudflare Access service token headers, under
Settings -> Advanced -> Custom headers:

  CF-Access-Client-Id:     <from the Zero Trust dashboard>
  CF-Access-Client-Secret: <from the Zero Trust dashboard>

Then redeploy so alert-relay picks up the new secret:

  ./scripts/deploy.sh stack

Verify the whole path end to end with:

  docker exec ${C} ntfy publish ${TOPIC} "test from the server"
--------------------------------------------------------------------
EOF
