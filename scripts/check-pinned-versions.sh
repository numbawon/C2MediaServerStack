#!/usr/bin/env bash
# Reports whether Traefik/Authentik (the two services deliberately pinned
# instead of floating on :latest -- see docker-stack.yml comments) are
# behind the newest available release. Read-only: never touches the
# stack, just prints findings so a go/no-go call can be made in a
# follow-up conversation (see the accompanying "is-it-new" skill for the
# release-notes/pros-cons half of that). Requires an authenticated `gh`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

current_traefik="$(grep -oP 'traefik:v\K[0-9]+\.[0-9]+' docker-stack.yml | head -1)"
current_authentik="$(grep -oP 'goauthentik/server:\K[0-9]+\.[0-9]+' docker-stack.yml | head -1)"

echo "== Traefik =="
echo "Pinned:  v$current_traefik"
latest_traefik="$(gh api repos/traefik/traefik/releases --paginate -q '.[].tag_name' \
  | grep -vE -- '-rc|-beta|-alpha|-ea' | sed 's/^v//' | grep -oE '^[0-9]+\.[0-9]+' \
  | sort -V -u | tail -1)"
echo "Latest:  v$latest_traefik"
if [ "$current_traefik" != "$latest_traefik" ]; then
  echo "-> Newer minor available: v$current_traefik -> v$latest_traefik"
  echo "   Release notes: https://github.com/traefik/traefik/releases/tag/v${latest_traefik}.0"
else
  echo "-> Up to date."
fi

echo
echo "== Authentik =="
echo "Pinned:  $current_authentik"
all_authentik="$(gh api repos/goauthentik/authentik/releases --paginate -q '.[].tag_name' \
  | grep -v -- '-rc\|-beta' | sed 's|^version/||;s/-stable$//' | grep -oE '^[0-9]{4}\.[0-9]+' \
  | sort -V -u)"
latest_authentik="$(echo "$all_authentik" | tail -1)"
echo "Latest:  $latest_authentik"
if [ "$current_authentik" != "$latest_authentik" ]; then
  echo "-> Behind. Authentik requires sequential major-version upgrades (no skipping)."
  echo "   Hops required, in order:"
  echo "$all_authentik" | sed -n "/^${current_authentik}\$/,\$p" | tail -n +2 | sed 's/^/     /'
  echo "   Release notes: https://docs.goauthentik.io/releases/<version>/ for each hop above."
else
  echo "-> Up to date."
fi
