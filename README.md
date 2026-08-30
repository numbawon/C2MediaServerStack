# C2MediaServerStack

A self-hosted media server stack for a single-node Docker Swarm host,
built around four ideas: **nothing is reachable except through one
gate** (Traefik + a Cloudflare Tunnel, zero open inbound ports),
**one login covers everything** (Authentik SSO, with three different
integration patterns depending on what each app actually supports),
**nothing touches the real Docker socket except one narrowly-scoped
proxy**, and **nothing here should assume it's your system**. That last
one is deliberate, not incidental: no real domain, credentials, or
tunnel IDs live in git history or tracked files (only `.example`
templates with placeholders do -- see "Setup order"); anywhere apps talk
to each other by hostname, that name reflects what the app actually is
rather than a routing implementation detail (`sonarr`, not
`vpn-client:8989`, even where the two happen to share a network
namespace -- see "VPN-routed download & indexer traffic"); and the one
piece of this repo that turned into genuinely general-purpose software
([Organizarr](https://github.com/numbawon/organizarr)) got split into
its own project, configured entirely through environment variables
instead of being wired to this stack's specific topology. It requests
media (Seerr), manages libraries (the `*arr` family + Prowlarr),
streams it back out (Plex, Navidrome), downloads things through a VPN,
and watches its own health (Prometheus/Grafana/Loki). This README
explains the whole thing well enough for someone else to stand it up
and actually understand what they're running, not just copy-paste it.

## What's in the stack

| Service | Role |
|---|---|
| **Traefik** | Reverse proxy. The only thing with an entrypoint; routes every hostname to the right backend. |
| **Cloudflare Tunnel** (`cloudflared`) | Outbound-only connection to Cloudflare's edge -- no port forwarding, no public IP exposure, ever. |
| **Authentik** | SSO. Gates almost everything behind a login before Traefik will even proxy the request. |
| **Postgres, Redis** | Authentik's database and session/cache store. |
| **Portainer** | Docker management UI, itself gated by Authentik (both the outer forward-auth gate *and* its own real OIDC login -- see below). |
| **Pi-hole** | Network-wide DNS ad-blocking; also this stack's local DNS. |
| **docker-socket-proxy** | The *only* thing that touches `/var/run/docker.sock` directly. Everything else that needs Docker API access goes through this, scoped to a minimal read-mostly permission set. |
| **Diun** | Watches registries and *notifies* when a newer image ships. It has no write access and updates nothing -- every bump is a deliberate decision. Replaced Watchtower; see "Updates". |
| **Prometheus, Alertmanager, alert-relay, ntfy** | The alert path. Prometheus evaluates rules, Alertmanager routes them, `alert-relay` formats them, ntfy pushes them to a phone. |
| **Recyclarr** | Syncs TRaSH Guides quality profiles and custom formats into Sonarr/Radarr. No web UI and no API: a cron'd one-shot, so there is no hostname and no Authentik application. |
| **Cleanuparr** | Removes stalled, blocked and known-malware downloads from the *arr queues and re-searches. Admin tier, because it deletes things. |
| **Audiobookshelf** | Audiobooks and podcasts. Household tier, native OIDC, deliberately not forward-auth gated. |
| **Immich** | Photos and video. Household tier, native OIDC, deliberately not forward-auth gated. Runs its own Postgres and Redis. |
| **Sonarr, Radarr, Lidarr, LazyLibrarian** | Library management for TV, movies, music, and ebooks -- find, grab, rename, organize. |
| **Bazarr** | Subtitle management for Sonarr/Radarr's libraries. |
| **Prowlarr** | Centralized indexer management -- add an indexer once, it syncs to every `*arr` app instead of configuring each separately. |
| **Seerr** | The request front-end (actively-maintained Overseerr fork) -- where you or your family actually ask for something to be added. |
| **qBittorrent** | Download client, with its traffic (and Sonarr/Radarr/LazyLibrarian's indexer-search traffic) forced through a VPN. |
| **Plex** | Media server / playback, GPU-transcoded. Deliberately *not* behind the SSO gate -- see "Authentik integration patterns." |
| **Navidrome** | Music streaming (Subsonic API) -- a dedicated music server, since Plex is only "fine" at it. |
| **Tautulli** | Plex watch-history/stats. |
| **Homer** | The dashboard -- one page linking to everything else. |
| **Organizarr** | Custom-built settings hub for the `*arr` apps -- see below. Admin tier. |
| **FlareSolverr** | Solves Cloudflare's JS challenge for the public indexers that would otherwise fail in Prowlarr. No UI, internal API only. |
| **Prometheus, Grafana, cAdvisor, node-exporter** | Metrics: host, per-container, and dashboards. |
| **Loki, Promtail** | Log aggregation -- searchable logs across every container, alongside the metrics. |

Two more pieces live *outside* Docker entirely, as host systemd services,
for disaster-recovery reasons explained further down: a web terminal
(`ttyd`) and a second, independent Cloudflare Tunnel that only does SSH.

## Architecture

**Ingress.** The only way in from the internet is the Cloudflare Tunnel.
It's an outbound-only connection from `cloudflared` to Cloudflare's edge
-- there's nothing listening on your router, nothing to port-forward,
and no public IP exposure at all. Cloudflare terminates TLS and forwards
matching hostnames to `cloudflared`, which hands everything to Traefik
on port 80. Traefik does all the actual host-based routing from there.

**Networks.** Two Docker overlay networks separate "things Traefik needs
to reach" from "things that should never be directly reachable by
anything except a specific trusted peer":

- `edge` -- external, attachable. Traefik, most apps, and the two
  standalone (non-Swarm) compose stacks all join this.
- `internal` -- Swarm-only, not attachable from outside. Postgres,
  Redis, the socket proxy, and anything that handles a trust-sensitive
  header (see Grafana/Navidrome below) live here instead, reachable
  only by other things also on `internal`.

**The Docker socket.** Only `docker-socket-proxy` ever touches the real
`/var/run/docker.sock`, and even then read-mostly: enough permission
bits for Traefik to discover services, Portainer to manage the stack,
Diun to enumerate image references, and Promtail to read container logs
-- nothing more. Everything else that would normally need direct socket
access (Traefik's provider, Portainer, Diun, Promtail) talks to the
proxy over `internal` instead. `DISTRIBUTION` is off: it existed only
so Watchtower could ask registries for digests, and Diun queries
registries directly over the internet rather than through the proxy. cAdvisor is the one deliberate
exception -- its per-container metrics need the real socket, so it's
kept internal-network-only and read-only-mounted to limit the blast
radius.

## Who can reach what: the access tiers

Being logged in is not the same as being allowed everywhere. Every gated
hostname resolves to an Authentik *application*, and each application
carries policy bindings naming the groups allowed through. Applications
use `policy_engine_mode = any`, so bindings are OR'd: `Admin` is bound
alongside each tier group rather than inheriting, which means an admin
never needs membership in the narrower groups.

| Tier | Group(s) bound | Apps |
| --- | --- | --- |
| Infrastructure | `Admin` | Portainer, Traefik dashboard, web terminal, Pi-hole, Organizarr |
| Media management | `Admin`, `Contributor` | Prowlarr, Sonarr, Radarr, Lidarr, LazyLibrarian, Bazarr, qBittorrent |
| Monitoring | `Admin`, `Metrics` | Grafana, Prometheus, Tautulli |
| Household | none (domain-level) | Seerr, Navidrome, Homer |

`Contributor` is for someone who genuinely helps run the library: they
can add indexers, manage every `*arr` app, and see the download queue.
`Metrics` is deliberately separate rather than folded into
`Contributor`, so dashboards can be handed out without library access
and vice versa; add a person to both if they need both. Tautulli in
particular exposes household viewing history, which is not something a
library helper automatically needs.

Organizarr stays `Admin` even though it is an `*arr` tool: it can
rewrite authentication settings and download-client credentials across
every connected app, which is a different kind of power from managing a
library.

The household tier has no dedicated application at all, so those
hostnames fall through to the domain-level provider, which has no policy
bindings: any authenticated user gets in. That is the media itself.

**Why the media-management tier moves as a block.** The `*arr` apps each
have an interactive/manual search that queries the same indexers Prowlarr
does and renders raw release titles, and qBittorrent lists every download
by name. Gating Prowlarr alone would leave six other doors to exactly the
same content, so the tier is drawn around the exposure rather than around
individual apps.

Two things this does *not* do:

- It does not touch internal traffic. Prowlarr pushing indexers to
  Sonarr, Bazarr querying Radarr, Organizarr reading every app's
  config -- all of that is container-to-container over the `edge`
  network and never passes through Traefik or Authentik. Gating a
  hostname only affects a browser arriving from outside.
- It does not hide the tiles. Homer renders the same dashboard for
  everyone, so lower-tier users still see links they cannot open and get
  an Authentik denial on click. The gate holds either way; it is
  cosmetic.

To move an app between tiers, add or remove a policy binding on its
Authentik application. Nothing in this repo or in Traefik changes, since
every gated router uses the same `authentik@file` middleware regardless
of tier -- which is exactly why the split is written down here.

## Authentik integration patterns

Not every app authenticates the same way -- this stack actually uses
three different patterns, chosen per app based on what it supports:

1. **Forward-auth gate (most apps).** Traefik's `authentik` middleware
   calls out to Authentik's outpost before proxying the request; an
   unauthenticated request gets redirected to login before it ever
   reaches the app. This is the default for everything -- Sonarr,
   Radarr, Pi-hole, Prometheus, Traefik's own dashboard, etc.

2. **Header-trust / auth-proxy (Grafana, Navidrome).** Some apps support
   trusting an externally-supplied identity header instead of doing
   their own login. Traefik's forward-auth check still runs first, and
   on success injects `X-authentik-username` (plus email/name) into the
   request; the app reads that header and auto-provisions a real,
   separate account per person -- actual per-user playlists/dashboards/
   history, just with one shared login. This only works because these
   apps also live on `internal`, not `edge` -- nothing except Traefik can
   reach them to forge that header.

3. **Real OIDC (Portainer).** A few apps get a dedicated Authentik
   OAuth2/OpenID provider + application (separate from the outer
   forward-auth gate) and do an actual login redirect into Authentik.
   Worth knowing if you set this up yourself: an OAuth2 group claim
   isn't automatically the same as an app's own "administrator" role --
   Authentik needs a custom `groups` scope mapping, and the target
   app's OAuth settings need an explicit "auto-assign admin rights to
   this group" option pointed at it, or every login just re-provisions
   a plain user.

**What's deliberately *not* gated:** Plex, and Navidrome's `/rest/*`
Subsonic API path. Native mobile/TV/car apps can't complete a
browser-redirect SSO challenge -- there's no browser to bounce through --
so both instead authenticate with their own app-level credentials
(Plex's own account system; a per-person password set once inside
Navidrome). Traefik splits Navidrome's single hostname on
`PathPrefix(/rest)` specifically to carry this off: the web UI goes
through the normal SSO gate, the API path doesn't.

## VPN-routed download & indexer traffic

The VPN container is [gluetun](https://github.com/qdm12/gluetun). It
replaced `bubuntux/nordvpn`, which was archived upstream; that image's
own boot log advised migrating to `bubuntux/nordlynx`, but that project
has since been archived too, so following its advice would have swapped
one dead project for another. gluetun is actively maintained, speaks
NordVPN's WireGuard (NordLynx) directly, and supplies the LAN proxy
below without a second container. The underlying transport did not
change in the migration -- the old setup already ran NordLynx, so the
same WireGuard private key carried straight over.

qBittorrent's traffic is forced through the VPN via
`network_mode: service:vpn-client` -- Docker Swarm has no equivalent of
sharing another container's network namespace, which is *the* reason
`docker-compose.download.yml` exists as a separate, non-Swarm compose
stack (see "Why three compose files" below). Sonarr, Radarr, and
LazyLibrarian share that same network namespace too, so their actual
*indexer searches* -- not just qBittorrent's downloads -- also exit
through the VPN instead of your home IP.

### Why Prowlarr is not behind the VPN

Sonarr, Radarr and LazyLibrarian exit through the VPN, but Prowlarr --
the app that actually performs the indexer searches -- does not. That is
deliberate, not an oversight.

The exposure the VPN exists to cover is *swarm participation*: monitoring
outfits join swarms and log peer IPs. That is qBittorrent, and it is
behind the VPN. Prowlarr never joins a swarm, never announces, and never
connects to a peer; it makes HTTPS requests to indexer sites and fetches
`.torrent` files. The residual exposure is that your ISP can see TLS SNI
to indexer domains and the indexer sees your residential IP, which is a
different category of thing from sharing a file.

Against that, routing Prowlarr through the VPN actively costs you:
Cloudflare challenges VPN and datacenter ranges far harder than
residential ones, and a number of public indexers block known VPN exit
ranges outright rather than merely challenging them. Exit IPs are also
shared, so somebody else's abuse becomes your ban with no visibility into
why.

If you do want specific indexers tunnelled, you do not need to move
Prowlarr at all. Prowlarr's **Indexer Proxies** feature supports plain
HTTP and SOCKS proxies alongside FlareSolverr, tagged per indexer, and
this stack already exposes an authenticated HTTP proxy on the VPN
container (see below). Point an HTTP proxy entry at
`${COMMON_LAN_IP}:8888`, tag it, and apply that tag only where you want
it. Do not put a proxy tag and the FlareSolverr tag on the same indexer;
FlareSolverr has its own proxy field if one genuinely needs both.

### Cloudflare-blocked indexers (FlareSolverr)

Some public indexers sit behind Cloudflare's JS challenge and simply fail
in Prowlarr. FlareSolverr runs a headless Chromium, solves the challenge,
and returns the `cf_clearance` cookie. Prowlarr supports it natively:
**Settings -> Indexers -> Indexer Proxies -> + -> FlareSolverr**, host
`http://flaresolverr:8191`, give it a tag such as `cloudflare`, then apply
that tag to only the indexers that need it. Tagging everything routes
every search through a browser for no reason.

It runs on `edge` next to Prowlarr rather than behind the VPN because the
`cf_clearance` cookie is bound to the IP and User-Agent that solved the
challenge -- if FlareSolverr exits from a different address than Prowlarr,
the cookie is rejected on first use.

Two honest limitations. FlareSolverr handles the older JS "I'm Under
Attack" challenge well but is unreliable against Cloudflare Turnstile,
which more sites are adopting; when an indexer stays broken with the tag
applied, this is usually why. And it is the one service here with a memory
limit, because every request spawns a Chromium and upstream has a long
history of memory growth under sustained use.

For private trackers, check whether the tracker offers a real API or
Torznab endpoint before reaching for FlareSolverr -- "blocked by
Cloudflare" often just means the indexer definition is HTML-scraping a
site that has a sanctioned API, and the API path does not break every
time the challenge changes.

### Using the VPN as a proxy from the rest of your LAN

gluetun exposes an authenticated HTTP proxy (CONNECT-capable, so HTTPS
works through it) on port 8888. Anything on your LAN pointed at it exits
through the VPN, which makes the tunnel usable from a laptop, phone, or
a single browser profile without installing a VPN client on that device.

It is published at `${COMMON_LAN_IP}:8888`, deliberately bound to this
host's LAN address rather than `0.0.0.0`: a proxy has no business
listening on every interface on the box. Credentials live in
`secrets/httpproxy_user.txt` and `secrets/httpproxy_password.txt`
(generated by `scripts/init-secrets.sh`) and are not optional --
an unauthenticated proxy is an open relay for anything that can reach
the port. Unauthenticated requests get a 407.

Point a client at `http://<user>:<password>@<COMMON_LAN_IP>:8888`, or
configure host/port plus credentials in your OS or browser proxy
settings. To confirm it is working:

```bash
curl -x "http://<user>:<password>@<COMMON_LAN_IP>:8888" https://ipinfo.io/json
```

The reported IP and city should be the VPN exit, not your ISP.

Note that this shares the tunnel with qBittorrent and the indexer
searches. It is a convenience path for occasional use, not a second
independent VPN connection.

Two consequences worth knowing if you extend this:

- Anything sharing `vpn-client`'s namespace has no independent network
  identity of its own -- one IP, differentiated only by port. Docker
  network aliases paper over this from the outside: `vpn-client`'s
  `networks.edge.aliases` registers `qbittorrent`/`sonarr`/`radarr`/
  `lazylibrarian` as additional names for that same IP, so everything
  *else* on `edge` (Traefik, Organizarr, Prowlarr's stored connections)
  addresses each app by its own natural name, same as if it had a real
  container of its own.
- *Inside* the shared namespace, that trick doesn't apply -- services
  there reach each other over `localhost`, not by name or alias. This
  is exactly why Sonarr/Radarr's own qBittorrent download-client host
  is `localhost:8080`, not `qbittorrent:8080`, even though everything
  outside the namespace uses the latter.

## Why three compose files

Docker Swarm can't do everything this stack needs:

| File | Runs as | Why it's separate |
|---|---|---|
| `docker-stack.yml` | Swarm stack (`docker stack deploy`) | Everything that doesn't hit a Swarm limitation |
| `docker-compose.download.yml` | Standalone compose | qBittorrent/Sonarr/Radarr/LazyLibrarian's traffic is forced through NordVPN via `network_mode: service:vpn-client` -- Swarm has no equivalent of sharing another container's network namespace |
| `docker-compose.plex.yml` | Standalone compose | NVIDIA GPU reservation (`deploy.resources.reservations.devices`) and the plain `devices:` key are ignored/unsupported by `docker stack deploy` |

Both standalone files join the same `edge` overlay network as the Swarm
stack (created once, attachable) so Traefik can still route to them --
via static entries in `traefik/dynamic/dynamic.yml`, since Traefik's
Docker provider in `swarmMode` doesn't auto-discover plain containers
by label.

## Before you start

- **A domain**, added to a Cloudflare account with nameservers pointed
  there. This stack has no wildcard DNS record by design -- each
  hostname gets its own explicit CNAME via `cloudflared tunnel route
  dns` (see Setup order), so pick your subdomains as you go.
- **Backblaze B2** (or your own S3-compatible target): account + bucket
  created for off-site backups.
- **NordVPN**: your WireGuard (NordLynx) private key, from the manual-setup
  section of your NordVPN dashboard. An account access token is no longer
  used -- gluetun speaks WireGuard directly rather than driving NordVPN's CLI.
- **Plex**: an account, ready to grab a claim token at deploy time
  (they expire in ~4 minutes).
- Docker Engine + Compose plugin, `cloudflared` CLI for one-time tunnel
  setup (`yay -S cloudflared` or the static binary from Cloudflare).
- **Pin image tags before first deploy.** A handful of images are
  pinned deliberately (Traefik, Postgres, Authentik) because a version
  jump there breaks config syntax or data compatibility -- see
  `scripts/check-pinned-versions.sh` and the `is-it-new` pattern in the
  comments near those services before bumping them. Everything else is
  on `:latest`, and *nothing* auto-updates -- Diun notifies you when a
  newer image ships and you decide. Check current tags yourself before
  first deploy rather than trusting `:latest` blindly.
- **Pi-hole vs systemd-resolved**: Pi-hole needs port 53. Check
  `sudo ss -tlnp | grep :53` -- if `systemd-resolved`'s stub listener is
  bound there, disable it (`DNSStubListener=no` in
  `/etc/systemd/resolved.conf`, then
  `sudo systemctl restart systemd-resolved`) before deploying Pi-hole,
  or it'll fail to bind.

## Setup order

```bash
cp .env.example .env
$EDITOR .env                       # fill in real values, including your domain

# Real per-deployment config (your domain, tunnel IDs) is git-ignored --
# copy these templates and fill in your own values:
cp cloudflared/config.yml.example cloudflared/config.yml
cp cloudflared/emergency-config.yml.example cloudflared/emergency-config.yml
cp homer/config.yml.example homer/config.yml
$EDITOR cloudflared/config.yml cloudflared/emergency-config.yml homer/config.yml

chmod +x scripts/*.sh
./scripts/bootstrap.sh             # docker swarm init + create the `edge` network

# --- Cloudflare Tunnel (one-time) ---
cloudflared tunnel login
cloudflared tunnel create mediastack
# For each hostname you're routing (traefik, auth, pihole, portainer, sonarr,
# radarr, lidarr, bazarr, seerr, lazylibrarian, prowlarr, tautulli, navidrome,
# organizarr, grafana, prometheus, plex, qbittorrent, and the bare domain for
# homer):
cloudflared tunnel route dns mediastack <sub>.yourdomain.com
# Grab the tunnel token for init-secrets.sh next: Cloudflare Zero Trust
# dashboard -> Networks -> Tunnels -> mediastack -> Configure -> copy token
# (or `cloudflared tunnel token mediastack`)

./scripts/init-secrets.sh          # prompts for Cloudflare/NordVPN/Plex values, generates the rest

docker stack deploy -c docker-stack.yml mediastack
docker compose -f docker-compose.download.yml up -d
docker compose -f docker-compose.plex.yml up -d
```

## Authentik first boot

Can't be scripted via env vars -- Authentik configures this through its
own UI after first start:

1. Visit `https://auth.yourdomain.com/if/flow/initial-setup/`, create
   the admin account.
2. **Applications -> Providers -> Create**: type *Proxy Provider*, mode
   *Forward auth (single application)*, external host
   `https://auth.yourdomain.com`.
3. **Applications -> Outposts**: use the embedded outpost, assign the
   provider you just made to it.
4. `traefik/dynamic/dynamic.yml`'s `authentik` middleware already points
   at `http://authentik-server:9000/outpost.goauthentik.io/auth/traefik`
   -- matches the embedded outpost's default path, nothing to change
   there.
5. Every service in `docker-stack.yml` already carries
   `traefik.http.routers.<name>.middlewares=authentik@file` -- once the
   outpost is live, hitting any of those URLs redirects to an Authentik
   login first.

That covers the default forward-auth gate every app gets automatically.
For the two other patterns from "Authentik integration patterns" above:

- **Header-trust (Grafana/Navidrome-style):** nothing extra to set up
  in Authentik -- the identity header rides along with the forward-auth
  check you just configured. On the app side, point it at
  `X-authentik-username` (Grafana's `GF_AUTH_PROXY_*` env vars,
  Navidrome's `ND_EXTAUTH_*`) and make sure it's on `internal`, not
  `edge`, so nothing else can forge that header.
- **Real OIDC (Portainer-style):** create a *second*, separate OAuth2/
  OpenID Provider + Application in Authentik (don't reuse the proxy
  provider above -- different provider types, one app per provider).
  Point the target app's OAuth settings at Authentik's standard
  `/application/o/{authorize,token,userinfo}/` endpoints. If the app
  needs real role/permission mapping (not just login), add a custom
  `groups` scope mapping in Authentik and wire the app's own
  "auto-assign admin to this group" setting to it -- a plain OAuth login
  by itself only proves identity, not authorization.

  Two things cost hours on the Immich and Audiobookshelf providers. Check
  both on any new one.

  **Set `grant_types` explicitly.** Creating a provider through `ak shell`
  with `OAuth2Provider.objects.get_or_create(...)` leaves that field
  EMPTY rather than applying the model default. Authentik then rejects
  every authorization-code request with `invalid_request` / "The request
  is otherwise malformed", and the app reports something vague like
  "Failed to finish oauth". The giveaway is only in Authentik's log:

  ```
  event: "Invalid grant_type for provider"
  grant_type: "authorization_code"
  ```

  `['authorization_code', 'refresh_token']` covers a browser app with a
  mobile client. A provider created through the web UI instead gets every
  grant type including `password` and `client_credentials`, which these
  apps have no use for.

  **Set the app's "match existing user by" rule before the first login.**
  Unset, the first OIDC login creates a NEW local account rather than
  linking to the existing admin. Two accounts then share a username,
  which breaks *local* login as well, because the lookup finds the OIDC
  account and that one has no password. Recovery means moving the stored
  subject claim onto the original account and deleting the duplicate.
  Matching on email avoids it entirely, and needs the email actually
  populated on both sides -- Authentik had it, Audiobookshelf did not.

  Diagnose either from Authentik, not the app. The app only ever sees a
  generic failure; Authentik logs the precise reason:

  ```
  docker logs <authentik-server> 2>&1 | grep -iE "invalid_client|grant_type|malformed"
  ```

Plex is deliberately excluded from any of this (see
`traefik/dynamic/dynamic.yml` comment) -- its own mobile/TV apps can't
complete a browser SSO redirect. It relies on your Plex account
instead, same reasoning as Navidrome's `/rest/*` Subsonic path.

## Directory layout expected under your media root

Matches what's already there -- no new folders created. Set
`COMMON_MEDIA` in `.env` to wherever this lives on your host:

```
Movies/          -> Radarr, Plex, Bazarr
TV/              -> Sonarr, Plex, Bazarr
Music/           -> Lidarr, Plex, Navidrome
EBooks/          -> LazyLibrarian, Plex
Pictures/        -> Immich, as a read-only External Library
(anything else)  -> Plex only, via its full data mount
```

`COMMON_DOWNLOADS` and `COMMON_COMPLETED` (also set in `.env`) are
qBittorrent's active/completed folders, also mounted into Sonarr/
Radarr/Lidarr/LazyLibrarian so they can import finished downloads.

**Keep all three on one filesystem.** The *arr apps import by hardlinking
out of the download folder into the library, which only works within a
single filesystem. Put the library on one mount and the downloads on
another and every import silently becomes a full byte-for-byte copy that
runs at disk speed, doubles the space used until the torrent is removed,
and gives no error to tell you it happened. Here that filesystem is a
single btrfs volume spanning three disks (`-d single -m raid1`), mounted
at `/mnt/Media`, holding `Movies/`, `TV/`, ... alongside `Downloads/` and
`Completed/`.

### Things that are not libraries

Two dot-prefixed directories sit at the array root:

```
.appdata/immich/   -> Immich's managed store (COMMON_APPDATA)
.backups/local/    -> config-volume snapshots (COMMON_BACKUP_LOCAL)
```

They are dot-prefixed on purpose. Immich's store in particular is
bookkeeping, not a library: it is `library/ upload/ thumbs/
encoded-video/ profile/ backups/`, six internal folders that Immich owns
and that mean nothing to anything else. Left at the library root it shows
up in every `ls`, in Plex's folder picker, and in anything that walks the
tree looking for media. It still has to be on the array rather than in a
Docker named volume, because every photo the household uploads lands in
it and the OS SSD has no room to grow into.

The photos that already existed are a separate thing: they stay in
`Pictures/` and Immich indexes them in place, read-only, as an External
Library (`/external/pictures` inside the container). Nothing is moved
into Immich's store, and a delete in the Immich UI cannot reach them.

## Local AI (Ollama + Open WebUI)

`docker-compose.ai.yml`, deployed with `./scripts/deploy.sh ai`. Reachable
at `ai.<domain>`, gated to the Admin and Contributor tiers.

### Why it is not in the Swarm stack

`docker stack deploy` ignores GPU reservations. It does not warn, it does
not fail: the service comes up, works, and runs every model on the CPU at
a fraction of the speed, with nothing anywhere reporting that the card is
idle. Same reason Plex is a standalone compose.

### The GPU wiring, and the trap in it

`driver: nvidia` with `capabilities: [gpu]`, exactly what Plex uses. No
`daemon.json` change and no Docker restart is needed, because
`nvidia-container-toolkit`'s prestart hook injects the driver libraries
and `nvidia-smi` into the container at start.

That injection only works on glibc images. Point the identical block at an
Alpine image and the `/dev/nvidia*` nodes appear, `nvidia-smi` does not,
and CUDA never initialises. The device nodes showing up makes it look like
the GPU passed through when nothing usable did. Ollama and Open WebUI are
both Debian-based, so this is fine here, but do not assume it survives a
switch to an Alpine variant.

Docker 25+ also supports CDI directly (`--device nvidia.com/gpu=all`
against the spec in `/etc/cdi/nvidia.yaml`), which does work on Alpine
because it bind-mounts rather than running `ldconfig`. Compose does not
drive that path the same way, which is why this uses the older reservation
syntax.

### Sizing, because 8 GB is the whole constraint

The card reports 7.6 GiB total and about 6.4 GiB actually free, since the
desktop session holds roughly 1.1 GB. An 8B model at Q4_K_M occupies
around 4.9 GB loaded, which leaves well under 2 GB for KV cache. Three
settings keep that from falling over, and none of them are the default:

| Setting | Default | Why it is changed |
| --- | --- | --- |
| `OLLAMA_MAX_LOADED_MODELS=1` | several | A second model does not fit. |
| `OLLAMA_NUM_PARALLEL=1` | 4 | Each slot gets its own KV cache. Four multiplies context memory by four and OOMs mid-generation. |
| `OLLAMA_KEEP_ALIVE=5m` | 5m | Kept explicit: Plex transcodes on this same card, and a model idling in VRAM competes with NVENC. |

Models live on the array (`COMMON_APPDATA/ollama`), not in a named volume.
They are multi-GB each and the OS SSD has under 80 GB free.

### Ollama has no authentication

None. Not "weak", none: anything that can reach port 11434 can load
models, run inference and delete them. So it is not on the `edge` overlay
and has no Traefik router. It sits on a private bridge that only Open
WebUI joins. If you ever give it a route, understand you are publishing an
unauthenticated API.

### OIDC

Open WebUI does real OIDC against Authentik, so there is no
`authentik@file` middleware in front of it, same as Immich and
Audiobookshelf. Unlike those two it reads its credentials from environment
variables rather than its own settings UI, so they live in `.env`.

Roles come from the `groups` claim, the same pattern Portainer uses.
`OAUTH_ALLOWED_ROLES=Admin,Contributor,Family` decides who may sign in and
`OAUTH_ADMIN_ROLES=Admin` decides who administers it. `Family` is included
deliberately: this is open to the whole household. Everyone shares one
8 GB card that Plex also transcodes on, and `MAX_LOADED_MODELS=1` means
concurrent requests queue rather than run in parallel.

### Household visibility

Part of why this exists is to teach kids to use AI well, which means an
admin has to be able to read back what was actually asked. Three settings
decide whether that is possible, and two of them default against it:

| Setting | Default | Set to | Effect |
| --- | --- | --- | --- |
| `ENABLE_ADMIN_CHAT_ACCESS` | true | true | Admins can read any user's chats. Stated explicitly so an upstream default change shows up here rather than silently removing the capability. |
| `USER_PERMISSIONS_CHAT_TEMPORARY` | true | **false** | Left on, any user flips "Temporary Chat" in the UI and that conversation is never written to the database. |
| `USER_PERMISSIONS_CHAT_DELETE` | true | **false** | A saved chat that can be deleted is a record only until someone decides otherwise. |

Temporary Chat is the one that matters. It is a single toggle in the chat
UI, it is on by default, and a conversation held that way is not hidden or
private, it is absent. No amount of admin access recovers it afterwards,
because nothing was ever stored.

`USER_PERMISSIONS_CHAT_DELETE_MESSAGE` is left at its default of true, so
individual messages can still be removed from a conversation. Turn it off
too if whole-conversation integrity matters more than letting someone
clean up a bad prompt.

Open WebUI shows users no indication that an administrator can read their
conversations, so `WEBUI_BANNERS` adds one. It is set `dismissible: false`
deliberately: a notice you click away once and never see again is not a
notice.

That banner is not a legal formality, it is the actual lesson. These tools
are monitored in nearly every school and workplace tenant, usually without
saying so anywhere in the interface. An instance that quietly behaved
better than that would teach exactly the wrong instinct. Knowing to assume
someone can read it is the transferable skill; this is just the one place
where the assumption is stated out loud.

The provider needs `grant_types` set explicitly. Creating one through the
ORM leaves that field empty because no model default is applied, and the
resulting failure is an opaque client error with nothing useful in the
logs. This cost hours on Immich and Audiobookshelf; see the OIDC pitfalls
section above.

### A new hostname needs its own DNS record

The tunnel ingress is already a wildcard (`*.<domain>` to Traefik), so
adding a service needs no cloudflared config change. It does need a CNAME,
which the wildcard does not provide:

```bash
cloudflared tunnel route dns mediastack ai.yourdomain.com
```

Without it the name simply does not resolve, which looks like the service
being down rather than like a missing record.

## Backups

- **Local** (`scripts/backup-local.sh`): tars every app's config volume
  to `<backup-root>/local/<timestamp>/`, keeps 14 days.
- **Off-site** (`scripts/backup-offsite.sh`): same volumes, via
  `restic` to Backblaze B2, encrypted. Needs `secrets/restic.env`
  (git-ignored) first:

  ```
  RESTIC_REPOSITORY=b2:your-bucket-name:mediastack
  RESTIC_PASSWORD=<pick a strong password -- losing it loses the backup>
  B2_ACCOUNT_ID=<Backblaze application key ID>
  B2_ACCOUNT_KEY=<Backblaze application key>
  ```

Both run on a schedule via the unit files in `systemd/` (local nightly
at 02:00, off-site at 03:30):

```bash
sudo cp systemd/mediastack-backup-local.{service,timer} \
        systemd/mediastack-backup-offsite.{service,timer} \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mediastack-backup-local.timer mediastack-backup-offsite.timer
```

Media itself is intentionally not covered by either backup -- too
large, and not ephemeral container state. Every unit file under
`systemd/` has your real repo path baked in as `/home/youruser/...` --
edit that to match your actual login user and install location before
copying it in.

**A note on trusting a backup script:** a script that exits 0 isn't
proof it backed up everything -- this project's own history includes a
real case where a subtle tar-implementation quirk silently truncated a
backup run partway through the volume list with no visible error.
Actually run a restore periodically (an isolated scratch volume, not
the live one) rather than assuming success from a clean exit code.

### Recovering after a host reboot

`docker-stack.yml` (Swarm) reconciles itself automatically once the
daemon comes back. The two standalone compose files don't -- in
particular, `qbittorrent`'s `network_mode: service:vpn-client` doesn't
reliably survive a full daemon restart, so it can come back `Exited`
even though `vpn-client` itself started fine.
`systemd/mediastack-recovery.service` re-applies both standalone
compose files (idempotent) once at boot to catch this:

```bash
sudo cp systemd/mediastack-recovery.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mediastack-recovery.service
```

### Emergency access if the whole Docker stack is down

Two host-level (non-Docker) pieces exist specifically for the scenario
where Traefik/Authentik/the SSO gate itself is what's broken:

- **`systemd/ttyd.service`** -- a web terminal bound to the
  `docker_gwbridge` gateway IP (reachable from Traefik, not from the
  LAN/WAN directly), routed by a static Traefik entry so it's still
  reachable through the normal domain even if most of the stack is
  unhealthy. Gated by real PAM login (`ttyd ... login`), independent of
  Authentik.
- **`systemd/cloudflared-emergency.service`** -- a second, *independent*
  Cloudflare Tunnel (separate tunnel ID from the Docker one) that does
  nothing but forward raw SSH, gated by Cloudflare Access with
  short-lived certs instead of Authentik. Keeps working even if Docker
  itself won't start. `systemd/10-mediastack-hardening.conf` is the
  companion `sshd` drop-in -- key-only auth, plus trusting Access's
  short-lived certificate authority.

Neither depends on anything inside the Swarm stack.

## Organizarr -- one place for the settings that were painful to keep straight

A standalone open-source project -- [numbawon/organizarr](https://github.com/numbawon/organizarr),
image pulled from `ghcr.io/numbawon/organizarr` like everything else in
this stack -- that surfaces the handful of settings genuinely annoying
to keep consistent across the `*arr` apps by hand: authentication
method, download-client host/port, and Prowlarr's application/indexer
sync. It's not a clone of each app's full settings UI -- only the
fields actually worth centralizing.

Every app it manages is configured entirely through `<NAME>_URL` /
`<NAME>_CONFIG_PATH` env vars on the service below (see that project's
own README for the full reference) -- nothing about which apps exist is
hardcoded.

It talks to each app's real API (never a config file) using an API key
read from that app's own config volume, mounted read-only -- lazily, not
once at startup: on a fresh deploy, Swarm doesn't guarantee this
container starts after the apps it depends on, and each of those apps
only writes its own API key on its own first boot. A miss just gets
retried on the next request instead of caching a permanent failure, so
plain `docker stack deploy` is enough -- no manual ordering, no restart,
no one needing to notice and intervene.

If an app's key genuinely can't be auto-detected (its volume isn't
mounted, an unusual setup), every app's section has a manual-override
field as a fallback -- auto-detection still wins the moment it starts
working, the override is a safety net rather than a permanent pin.
Overrides persist in the `organizarr_data` volume (covered by both
backup scripts).

**This one is in the Admin tier** (see "Who can reach what" above),
using the same
"single-application provider, Admins group only" pattern already used
for Pi-hole/Portainer/Traefik's dashboard (see "Authentik first boot"
above), *not* the any-authenticated-user default the rest of the apps
get. Organizarr can rewrite authentication settings and download-client
credentials across the whole stack, so it deserves the tighter gate.

If you are standing this up yourself, that means creating a Proxy
Provider (forward auth, single application) with external host
`https://organizarr.<your-domain>`, an Application bound to it, a
policy binding for your Admins group, and adding the provider to the
embedded outpost. The Traefik side needs no special handling -- the
router keeps the ordinary `authentik@file` middleware, and the outpost
picks the most specific matching application by hostname.

## Monitoring & logs

Every service sets `TZ=${COMMON_TZ}` so logs read in local time rather
than a mix of local and UTC, which matters when correlating an incident
across Loki. Containers cannot drift from the host clock -- they share
the host kernel's clock and no time namespace is in use -- so the host's
NTP sync is the only thing that ever needs to be right, and `TZ` only
ever affects *display*. The one exception is Diun, whose watch schedule
is genuinely interpreted in the container's timezone -- `TZ` is not
cosmetic there.

A handful of images hardcode UTC in their own log output regardless of
`TZ` (Loki, cloudflared, Portainer, Navidrome). That is not worth
fighting: Loki in particular stores every ingested timestamp in UTC
internally by design, which is correct, and Grafana renders it back in
whatever timezone you are viewing from.


- **Prometheus** scrapes itself, `node-exporter` (host metrics),
  `cadvisor` (per-container metrics), and Traefik's own metrics
  endpoint -- see `prometheus/prometheus.yml`.
- **Grafana** is provisioned with Prometheus and Loki as datasources
  out of the box (`grafana/provisioning/`) and uses the header-trust
  pattern above instead of its own login.
- **Loki + Promtail** aggregate logs from every container, discovered
  through the socket proxy's existing `CONTAINERS` permission -- no raw
  socket mount, no host log-directory bind mount, just the same trust
  boundary as everything else. If you add services later, their logs
  show up automatically; nothing per-service to configure.
- **Alertmanager** routes what Prometheus fires; **alert-relay**
  (in-repo, `alert-relay/relay.py`) turns Alertmanager's fixed JSON
  webhook into a readable notification; **ntfy** pushes it to a phone.
  Alert rules live in `prometheus/rules/`. See "Alerting" below.
- **Diun** replaced Watchtower. See "Updates" below for why.

## The apps that are not forward-auth gated

Four services deliberately carry no `authentik@file` middleware, and it
is the same reason every time: **each has a native client that cannot
complete a browser login redirect.**

| service | why | what protects it instead |
|---|---|---|
| Plex | its own TV/mobile apps | Plex's own account system |
| Navidrome `/rest/*` | Subsonic API clients | per-person Subsonic password |
| ntfy | Android app holds a persistent connection | Cloudflare Access service token + ntfy tokens |
| Audiobookshelf | mobile app | native OIDC against Authentik |
| Immich | mobile app | native OIDC against Authentik |

Putting the forward-auth gate in front of any of them does not "add
security", it breaks the app: every API call gets bounced to a login
page the client cannot render. **Do not add `authentik@file` to these
routers for consistency.**

Audiobookshelf and Immich are pattern 3 (real OIDC), not pattern 1. The
Authentik side is already created (`Audiobookshelf OIDC`, `Immich OIDC`
providers plus their applications); the app side is configured in each
app's own UI after first boot, because neither accepts OIDC settings as
environment variables:

- **Audiobookshelf**: Settings -> Authentication -> enable OpenID
  Connect. Paste the issuer URL and click Auto-populate, then fill in
  the client ID and secret. Add the mobile redirect URI under *Allowed
  Mobile Redirect URIs*.
- **Immich**: Administration -> Settings -> OAuth Authentication.

Client IDs and secrets are in `secrets/oidc-clients.env` (git-ignored).
Issuer URL for both:
`https://auth.<domain>/application/o/<app-slug>/.well-known/openid-configuration`

## Recyclarr

Recyclarr is the complement to Organizarr: Organizarr centralizes auth
and download-client settings, Recyclarr owns quality profiles and custom
formats from the TRaSH Guides.

Three things about it are easy to get wrong, all of which cost time here:

- **There is no `:latest` tag.** Only major-version tags. `:latest` gets
  `manifest unknown` and Swarm rejects the task in a loop.
- **It must be version 8, not 7.** The official config templates track
  the v8 schema and use `quality_profiles: - trash_id:`, which v7 cannot
  parse; on 7 the sync dies with a bare `Exception at line 30`.
- **The templates are complete configs, not includes.** There is no
  `includes` directory in the template repo, so
  `include: - template: <name>` never resolves and fails with "unable to
  find config include with name". `recyclarr/configs/*.yml` are copies of
  the official templates with `base_url` and `api_key` filled in, which
  is exactly what `recyclarr config create --template` would produce.

`reset_unmatched_scores` is turned **off**, against the template default.
The template ships it as `true`, which zeroes the score of every custom
format the guide does not explicitly set, including anything tuned by
hand. A daily cron should not quietly undo manual work.

The first sync created new profiles rather than modifying existing ones
(37 custom formats and a `WEB-1080p` profile in Sonarr, 40 and
`HD Bluray + WEB` in Radarr), so pre-existing profiles were untouched.

## DNS

Four moving parts, three of which live outside this repo. Written down
because a silent change to any of them breaks something that looks
unrelated.

```
LAN device ---> asks the router (DHCP tells it to)
                  |
                  +-- DNS Director DNATs :53 to Pi-hole
                          |
this server ------------> Pi-hole (blocklists)         [127.0.0.1]
                          |
                          +-- forwards to the router   [MAC-exempt, no loop]
                                  |
                                  +-- stubby -> DNS-over-TLS -> Cloudflare
```

**Router (nvram, not in this repo).** `dnsfilter_enable_x=1`,
`dnsfilter_mode=8` ("User Defined 1"), `dnsfilter_custom1` = Pi-hole.
`dnspriv_enable=1` with `dnspriv_profile=1` (opportunistic) and
Cloudflare's IPv4 DoT servers. IPv6 upstreams are deliberately omitted:
this host has no IPv6 route and they fail with "Network unreachable".

**The MAC exemption is load-bearing.** DNS Director's client list holds
this server's MAC set to "No Redirection", solely so Pi-hole's own
upstream queries can reach the router instead of being DNAT'd back to
Pi-hole. Remove it and DNS dies house-wide immediately.

**The DHCP lease says the ROUTER, and that is correct.** Asuswrt
suppresses DHCP option 6 whenever DNS Director is enabled, so
`dhcp_dns1_x` is stored but never emitted. Clients are told to use the
router and then silently redirected. A lease showing the router's address
is not a symptom of anything.

**This server needs its own resolver pinned.** It is MAC-exempt, so
without intervention its own browsing skips Pi-hole entirely -- encrypted
by DoT, but unfiltered. NetworkManager is set to
`ipv4.dns "127.0.0.1 <router>"` with `ipv4.ignore-auto-dns yes`. Pi-hole
runs with `network_mode: host`, so loopback reaches it directly. Without
`ignore-auto-dns`, a DHCP renewal silently reverts this and the desktop
stops being filtered.

**Pi-hole settings are NOT locked via FTLCONF_ env vars**, apart from
`misc_dnsmasq_lines`. Anything set that way becomes read-only in the web
UI, which is a worse trade than declaring it here. The consequence is
that `dns.listeningMode` and `dns.upstreams` live only in the
`pihole_config` volume; both backup scripts cover it.

`filter-AAAA` is deliberate policy, not a leftover workaround. It was
originally added because the router SERVFAILed every AAAA query and
musl-based containers fail the entire lookup when either half fails. The
router has since been fixed, so that reason is gone -- but a second,
better reason replaced it.

**This network has no IPv6 at all.** Not "IPv6 is disabled": there is no
prefix and no route, end to end.

```
host: 0 global v6 addresses, 0 default v6 routes, curl -6 -> HTTP 000
router: ipv6_service=ipv6pt (passthrough), ipv6_prefix empty,
        ipv6_wan_addr empty, ping6 -> Network is unreachable
```

Handing out AAAA records on a v4-only network means clients try IPv6
first (RFC 6724 / Happy Eyeballs), fail to connect, and fall back.
Browsers absorb that in roughly 250ms. Plain-socket clients without Happy
Eyeballs -- the *arr apps, qBittorrent -- can stall on a full connect
timeout first. Suppressing AAAA is the correct configuration here, and
removing it would trade a cosmetic oddity for real latency.

The only visible artifact is that a blocked domain returns `::` for AAAA
instead of `0.0.0.0`. Both mean blocked.

If IPv6 is ever enabled, the order matters: switch the router off
passthrough, confirm the ISP actually delegates a prefix, verify gluetun
blocks IPv6 egress (`FIREWALL_OUTBOUND_SUBNETS` is IPv4-only, so the
*arr apps sharing its namespace could leak around the VPN), and only
then remove this.

### Blocklists

Three lists, deliberately few. Gravity holds ~2.4M domains.

| list | what for |
|---|---|
| Hagezi Multi PRO | the main blocklist; aggregates 200+ upstream sources |
| Hagezi Threat Intelligence Feeds | malware, phishing, scam domains |
| StevenBlack unified | belt and braces; heavy overlap with the above, harmless |

Two lists were removed. One pointed at a GitHub *web page* rather than a
raw file, so gravity imported SVG path data as domain names (entries like
`1.078-3.144-.292-.741`). The other was `StevenBlack/data/StevenBlack/hosts`,
94% of which is already in the unified list.

**The allowlist is empty on purpose.** Rather than importing a general
anti-breakage list, the domains this stack actually depends on were tested
against gravity directly: TMDB, TVDB, MusicBrainz, Plex, the container
registries, B2, Cloudflare, ntfy, the TRaSH guides and the rest. Zero false
positives. The only blocked results were `sentry.io` and
`notify.bugsnag.com`, which are telemetry and should stay blocked.

`anudeepND/whitelist` is the commonly-recommended Pi-hole allowlist and is
deliberately NOT used: its last commit was March 2024. Adding a stale
dependency to fix a problem that does not exist is how the Watchtower
situation happened.

Re-run that check after changing lists:

```
docker run --rm --network host alpine sh -c 'apk add -q bind-tools
for d in api.themoviedb.org api.thetvdb.com plex.tv musicbrainz.org \
         ghcr.io registry-1.docker.io api.backblazeb2.com; do
  printf "%-26s %s\n" "$d" "$(dig +short @<pihole> -t A $d | head -1)"
done'
```

An empty result or `0.0.0.0` means blocked. Note `filter-AAAA` makes
blocked domains return `::` for AAAA rather than `0.0.0.0`; both mean
blocked.

### Browser DNS-over-HTTPS

A browser doing its own DoH bypasses every layer above -- Pi-hole never
sees the query, so no blocklists, no query log, no per-client visibility.

Handled at the network level, not per-device: Pi-hole answers NXDOMAIN
for `use-application-dns.net` via `misc.dnsmasq_lines`. That is Mozilla's
documented opt-out signal. Firefox checks it on startup and disables DoH
on its own, which covers every Firefox on the LAN -- phones and laptops
included -- without touching anyone's browser settings.

It is a soft signal by design. Anyone can still tick "Enable DNS over
HTTPS" in Settings and override it, and that is intentional: an
enterprise policy file could enforce it, but locking a browser setting on
a machine someone actually uses is a worse trade than the marginal
coverage it buys.

Chrome is not installed. If it is ever added, it only auto-upgrades to
DoH when the system resolver is a recognised DoH provider, which Pi-hole
is not, so its default is already safe.

### What watches this

`blackbox-dns` checks that resolvers answer. `blackbox-dns-blocked`
checks that Pi-hole still *filters*, by querying a known-blocked domain
and requiring `0.0.0.0` -- the first passes just as happily when Pi-hole
has been bypassed and something upstream is answering in its place.
Verified in both directions: the probe returns `probe_success 0` against
the router and `1` against Pi-hole, with both returning an answer, so it
is inspecting content rather than reachability.

Not covered: this server's own `resolv.conf` regressing. That is a
NetworkManager setting no probe here can see.

## Backup verification

`scripts/backup-offsite.sh` exiting 0 proves an upload happened. It does
not prove the data comes back. `scripts/verify-backups.sh`, on a weekly
timer, is what actually checks:

- **Integrity, every run.** `restic check --read-data-subset=5%` walks
  the repository structure *and* downloads and hashes a random 5% of the
  real pack files. Structure-only checking would miss silent corruption
  in B2, which is the failure this exists to catch.
- **Restore, every 28 days.** Restores one volume out of the newest
  snapshot into a scratch directory and asserts the restored file count
  equals what the snapshot manifest lists. This is the only step that
  proves recovery, rather than that the bytes hash correctly.

Results are written as Prometheus metrics into the
`node_exporter_textfile` volume and served by node-exporter's textfile
collector, which is how a job that runs once a week becomes something
Prometheus can alert on continuously. `BackupVerificationStale` fires if
the timer itself stops, because "no failures reported" and "nothing is
checking" otherwise look identical.

Two details worth not re-learning:

- `restic ls` needs **`--recursive`**, or it lists only the top level
  (10 entries against 555 actual files) and the assertion fails every
  run. Use `--json` and count `"type":"file"` so directories are not
  counted against a `find -type f` total.
- restic runs as root inside its container, so the restored tree is
  root-owned and the script cannot delete it as an ordinary user.
  Cleanup runs in a throwaway container for that reason.

`secrets/` is included in the off-site backup and deliberately not in the
local one. It is git-ignored by design, which also means it exists in
exactly one place, and it holds the WireGuard key, the Plex claim token
and the ntfy credentials. restic encrypts before anything leaves the
host; the local job would only write a second plaintext copy to the same
disk.

## Updates

Nothing in this stack updates itself. **Diun** checks registries daily
and tells you when a newer image ships; you read the changelog and bump
it deliberately.

This replaced Watchtower, and the reason is worth writing down because
the old setup looked correct and was not:

- **Watchtower operates on containers, Swarm reconciles from service
  specs.** Every service in `docker-stack.yml` is digest-pinned in its
  spec (`docker service inspect` shows `traefik:v3.7@sha256:...`, and
  that includes the ones on `:latest`). If Watchtower had stopped a
  container to update it, Swarm would have recreated the task from the
  unchanged spec. The net effect was a restart, not an update.
- **The opt-out labels never applied.** They were written under
  `deploy.labels`, which are *service* labels. Watchtower reads
  *container* labels, and the task containers carried only
  `com.docker.stack.namespace`. So the `enable=false` on Traefik,
  Authentik, Postgres, Redis and the socket proxy protected nothing.
  This README previously claimed otherwise.
- It genuinely worked for the six standalone containers in
  `docker-compose.download.yml` / `.plex.yml`, which are real
  containers rather than Swarm tasks.

Diun avoids all of it by having a **Swarm provider** that reads services
directly, plus a Docker provider for the standalone containers. It gets
no write access and cannot restart anything.

Findings surface as the Prometheus metric
`diun_image_update_available{provider,image}`, which
`prometheus/rules/alerts.yml` turns into a notification through the same
path as every other alert. One alert pipeline, one place to silence.

Diun watches *registries*, not GitHub releases. That is the more
reliable signal here: several of these projects tag releases
inconsistently, but all of them have to push an image.

## Alerting

```
Prometheus (rules/) --> Alertmanager --> alert-relay --> ntfy --> phone
                                              ^
                             Diun metrics ----+ (scraped by Prometheus)
```

- **Rules** are in `prometheus/rules/alerts.yml`, kept deliberately
  small. A noisy alerting system gets muted, and a muted one is worse
  than none because you believe you have one.
- **Editing a rule is not enough to apply it.** The rules directory is a
  bind mount, so the new file is inside the container immediately, but
  Prometheus only re-reads it on SIGHUP. `docker stack deploy` will not
  do it either: if nothing in the service spec changed, Swarm leaves the
  running task alone and the old rules keep evaluating against the old
  thresholds, with no warning anywhere that the file on disk and the
  rules in memory have diverged. After editing:

  ```bash
  docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool \
    prom/prometheus:latest check rules /p/rules/alerts.yml
  docker kill -s HUP "$(docker ps -qf name=mediastack_prometheus)"
  ```

  Then confirm what is actually loaded, not what is on disk:
  `wget -qO- http://localhost:9090/api/v1/rules` from inside the
  container. The HTTP `/-/reload` endpoint returns 403 here, because
  `--web.enable-lifecycle` is deliberately not set: it would let anything
  that can reach port 9090 on the `edge` overlay reload or shut down
  Prometheus, and SIGHUP already does the job from the host.
- **`Watchdog`** always fires and is routed to a dead-end receiver, so
  it never notifies. Its job is to be *visible in Alertmanager's UI*.
  If you look and it is missing, the alert pipeline itself is broken --
  which is otherwise indistinguishable from "nothing is wrong".
- **`alert-relay`** is in this repo rather than an off-the-shelf bridge.
  There are five competing community Alertmanager-to-ntfy bridges, none
  official, and the best-maintained had not shipped in over a year. A
  dead relay fails *silently*, which is the worst possible failure mode
  for the thing that tells you about failures. It is stdlib-only Python
  on a stock `python:3-alpine`, so there is no image to build and
  nothing to rot.
- **Severity drives priority.** `critical` publishes at ntfy priority 5,
  which bypasses Android Do Not Disturb and is allowed to wake you.
  `warning` is 4, `info` is 3. Keep that distinction meaningful.

### ntfy is deliberately not behind Authentik

ntfy is the one internet-reachable service with no forward-auth gate.
The Android app holds a persistent connection and cannot complete a
browser login redirect, exactly like Plex and Navidrome's `/rest/*`
path. Putting `authentik@file` on its router breaks push delivery
entirely. **Do not "fix" this for consistency.**

What protects it instead, in layers:

1. **Cloudflare Access** with a service token at the edge, so
   unauthenticated requests never reach the ntfy process at all. The
   Android app sends `CF-Access-Client-Id` / `CF-Access-Client-Secret`
   via *Settings -> Advanced -> Custom headers*.
2. **`auth-default-access: deny-all`** in `ntfy/server.yml`, so anything
   that got past Cloudflare still needs a valid ntfy token.
3. **No published port.** Ingress is the Cloudflare Tunnel like
   everything else; there is no exposed origin IP.

Accounts are least-privilege: `relay` is write-only on the topic,
`phone` is read-only, neither is an admin. Run `scripts/init-ntfy.sh`
after the first deploy to create them and issue the tokens.

If an iPhone ever needs to subscribe, note that self-hosted ntfy must
set `upstream-base-url` to forward `poll_request` messages through
ntfy.sh for APNs. Message *content* stays on your server, but a ping per
alert transits a third party, and Cloudflare Access likely breaks the
iOS notification-service-extension fetch.

## Verification checklist

- `docker stack deploy -c docker-stack.yml mediastack` -- no
  undeclared-volume/secret errors.
- `docker service ls` -- all replicas up, nothing restart-looping.
- `cloudflared tunnel info mediastack` shows connected; `ss -tlnp` on
  the host shows nothing new bound to 80/443.
- Any app URL redirects to Authentik login before showing the app
  (except Plex, and Navidrome's `/rest/*`).
- Plex: start a transcoded stream, confirm `nvidia-smi` shows an
  ffmpeg process.
- `docker service update --force <service>` on something, confirm it
  recovers.
- Run `scripts/backup-local.sh` and `scripts/backup-offsite.sh`
  manually once; confirm output in `<backup-root>/local/` and
  `restic snapshots` (via
  `docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY restic/restic snapshots`,
  sourcing `secrets/restic.env` first).

## Rotating a secret

```bash
docker secret rm <name>
# update the services referencing it (docker service update, or redeploy the stack)
./scripts/init-secrets.sh   # re-creates it (skips ones that already exist otherwise)
```
