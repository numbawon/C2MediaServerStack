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
| **Watchtower** | Auto-updates anything on `:latest`, opt-out via label (used to keep Traefik/Authentik/Postgres/Redis/the socket proxy pinned). |
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
Watchtower to check for updates, and Promtail to read container logs --
nothing more. Everything else that would normally need direct socket
access (Traefik's provider, Portainer, Watchtower, Promtail) talks to
the proxy over `internal` instead. cAdvisor is the one deliberate
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
  on `:latest` and auto-updates via Watchtower; check current tags
  yourself before first deploy rather than trusting `:latest` blindly.
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
(anything else)  -> Plex only, via its full data mount
```

`COMMON_DOWNLOADS` and `COMMON_COMPLETED` (also set in `.env`) are
qBittorrent's active/completed folders, also mounted into Sonarr/
Radarr/Lidarr/LazyLibrarian so they can import finished downloads.

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
ever affects *display*. The one exception is Watchtower, whose cron
schedule is genuinely interpreted in the container's timezone (see
above).

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
- **Watchtower** auto-updates anything on `:latest`; anything that
  should never be silently updated (Traefik, Authentik, Postgres,
  Redis, the socket proxy) carries an explicit opt-out label
  (`com.centurylinklabs.watchtower.enable=false`) instead of relying on
  a default-off allowlist -- safer to have new services auto-update by
  default and remember to opt the sensitive ones out, than the other
  way around. Its `WATCHTOWER_SCHEDULE` cron is interpreted in the
  container's timezone, so `TZ` is not cosmetic here the way it is
  elsewhere: without it the 04:00 schedule ran at 04:00 UTC, which is
  21:00 locally and squarely in the middle of the evening. With `TZ`
  set it runs at 04:00 local, which is the point.

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
