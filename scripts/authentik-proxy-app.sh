#!/usr/bin/env bash
# Creates (or repairs) an Authentik forward-auth application for one hostname,
# gated to one or more groups, on the embedded outpost.
#
# Providers created by hand in `ak shell` come out missing three fields that
# the web UI fills in: redirect URIs, scope mappings and grant types. Without
# them the login dies with "Redirect URI Error" (a blank scope, or a missing
# grant type, both surface as that page). This script sets all three, so use it
# instead of typing the shell snippet again. It is idempotent: running it on an
# existing app fixes that app in place.
#
#   ./scripts/authentik-proxy-app.sh <slug> <host> <group[,group...]> [-DryRun]
#
#   ./scripts/authentik-proxy-app.sh syncthing syncthing.example.com Admin
#   ./scripts/authentik-proxy-app.sh scrutiny scrutiny.example.com Admin,Metrics
#
# <host> is the public hostname, without a scheme. Groups must already exist.
# The Traefik router that sends the host through the `authentik@file`
# middleware is separate (traefik/dynamic/dynamic.yml) and is not touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DRY_RUN=false
args=()
for arg in "$@"; do
  case "$arg" in
    -WhatIf|--whatif|-DryRun|--dry-run) DRY_RUN=true ;;
    *) args+=("$arg") ;;
  esac
done
if [ "${#args[@]}" -ne 3 ]; then
  echo "Usage: $0 <slug> <host> <group[,group...]> [-DryRun]" >&2
  exit 1
fi
SLUG="${args[0]}"
HOST="${args[1]}"
GROUPS_CSV="${args[2]}"

if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "slug must be lowercase letters, digits and hyphens: $SLUG" >&2
  exit 1
fi
if ! [[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "host must be a bare hostname, no scheme or path: $HOST" >&2
  exit 1
fi

worker=$(docker ps -q -f name=mediastack_authentik-worker | head -1)
if [ -z "$worker" ]; then
  echo "authentik worker container is not running" >&2
  exit 1
fi

# Values go in through the environment, never interpolated into the Python.
docker exec -i \
  -e AK_SLUG="$SLUG" -e AK_HOST="$HOST" -e AK_GROUPS="$GROUPS_CSV" \
  -e AK_DRY_RUN="$DRY_RUN" \
  "$worker" ak shell 2>&1 <<'PY' | sed -n 's/^RES //p'
import os
from authentik.core.models import Application, Group
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.models import PolicyBinding
from authentik.providers.oauth2.models import (
    RedirectURI, RedirectURIMatchingMode, ScopeMapping,
)
from authentik.providers.proxy.models import ProxyProvider

slug = os.environ["AK_SLUG"]
host = os.environ["AK_HOST"]
dry = os.environ["AK_DRY_RUN"] == "true"
names = [g.strip() for g in os.environ["AK_GROUPS"].split(",") if g.strip()]
base = "https://" + host

def out(msg):
    print("RES " + msg)

groups = []
for n in names:
    g = Group.objects.filter(name=n).first()
    if g is None:
        out("ERROR group not found: %s (have: %s)" % (
            n, ", ".join(sorted(x.name for x in Group.objects.all()))))
        raise SystemExit(1)
    groups.append(g)

# The five mappings every working proxy provider here carries. `ak_proxy`
# is the one the outpost needs; the rest give it a normal OIDC user.
want = [
    "authentik default OAuth Mapping: OpenID 'openid'",
    "authentik default OAuth Mapping: OpenID 'email'",
    "authentik default OAuth Mapping: OpenID 'profile'",
    "authentik default OAuth Mapping: Proxy outpost",
    "authentik default OAuth Mapping: Application Entitlements",
]
mappings = list(ScopeMapping.objects.filter(name__in=want))
if len(mappings) != len(want):
    out("ERROR missing scope mappings: %s" % (
        set(want) - {m.name for m in mappings}))
    raise SystemExit(1)

authz = Flow.objects.get(slug="default-provider-authorization-implicit-consent")
invalid = Flow.objects.get(slug="default-provider-invalidation-flow")
outpost = Outpost.objects.get(managed="goauthentik.io/outposts/embedded")
uris = [
    base + "/outpost.goauthentik.io/callback?X-authentik-auth-callback=true",
    base + "?X-authentik-auth-callback=true",
]

existing = Application.objects.filter(slug=slug).first()
out("%s %s -> %s, groups %s" % (
    "would update" if dry and existing else
    "would create" if dry else
    "updating" if existing else "creating",
    slug, base, ",".join(names)))
if dry:
    raise SystemExit(0)

provider, _ = ProxyProvider.objects.update_or_create(
    name=slug,
    defaults=dict(
        mode="forward_single",
        external_host=base,
        authorization_flow=authz,
        invalidation_flow=invalid,
        client_type="confidential",
        grant_types=["authorization_code"],
        redirect_uris=[
            RedirectURI(RedirectURIMatchingMode.STRICT, u) for u in uris],
    ),
)
provider.property_mappings.set(mappings)
provider.save()

app, _ = Application.objects.update_or_create(
    slug=slug, defaults=dict(name=slug.replace("-", " ").title(),
                             provider=provider))

# Group gating: bind exactly the requested groups, nothing else.
PolicyBinding.objects.filter(target=app).exclude(group__in=groups).delete()
for order, g in enumerate(groups):
    PolicyBinding.objects.update_or_create(
        target=app, group=g, defaults=dict(order=order, enabled=True))

outpost.providers.add(provider)
outpost.save()  # makes the embedded outpost reload its provider list
out("done: %s (redirect URIs %d, scopes %d, grant types %s)" % (
    slug, len(provider.redirect_uris), provider.property_mappings.count(),
    provider.grant_types))
PY
