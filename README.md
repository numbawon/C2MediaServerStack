# C2MediaServerStack

Media server stack for `example.com`, running on a single-node Docker Swarm
with room to add nodes later. Traefik reverse-proxies everything, gated by
Authentik SSO, reached from the internet only via a Cloudflare Tunnel (no
open inbound ports). Two pieces intentionally run outside the Swarm stack —
see "Why three compose files" below.

## Why three compose files

Docker Swarm can't do everything this stack needs:

| File | Runs as | Why it's separate |
|---|---|---|
| `docker-stack.yml` | Swarm stack (`docker stack deploy`) | Everything that doesn't hit a Swarm limitation |
| `docker-compose.download.yml` | Standalone compose | qBittorrent's traffic is forced through NordVPN via `network_mode: service:vpn-client` — Swarm has no equivalent of sharing another container's network namespace |
| `docker-compose.plex.yml` | Standalone compose | NVIDIA GPU reservation (`deploy.resources.reservations.devices`) and the plain `devices:` key are ignored/unsupported by `docker stack deploy` |

Both standalone files join the same `edge` overlay network as the Swarm
stack (created once, attachable) so Traefik can still route to them —
via static entries in `traefik/dynamic.yml`, since Traefik's Docker
provider in `swarmMode` doesn't auto-discover plain containers by label.

## Before you start

- **Cloudflare**: `example.com` added to a Cloudflare account, nameservers pointed there.
- **Backblaze B2** (or your own S3-compatible target): account + bucket created for off-site backups.
- **NordVPN**: an access token from your NordVPN dashboard.
- **Plex**: an account, ready to grab a claim token at deploy time (they expire in ~4 minutes).
- Docker Engine + Compose plugin (already present on this host), `cloudflared` CLI for one-time tunnel setup (`yay -S cloudflared` or the static binary from Cloudflare).
- **Pin image tags before first deploy.** A handful of images below are pinned (Traefik, Postgres, Authentik) because a version jump there breaks config syntax or data compatibility. Everything else is on `:latest` deliberately left for you to pin to whatever's actually current — my knowledge of exact current tags isn't reliable this far out, don't trust `:latest` blindly either. Check each image's tags on Docker Hub / GHCR and pin explicit versions in `docker-stack.yml`, `docker-compose.download.yml`, and `docker-compose.plex.yml` before going live.
- **Pi-hole vs systemd-resolved**: Pi-hole needs port 53. Check `sudo ss -tlnp | grep :53` — if `systemd-resolved`'s stub listener is bound there, disable it (`DNSStubListener=no` in `/etc/systemd/resolved.conf`, then `sudo systemctl restart systemd-resolved`) before deploying Pi-hole, or it'll fail to bind.

## Setup order

```bash
cp .env.example .env
$EDITOR .env                       # fill in real values

chmod +x scripts/*.sh
./scripts/bootstrap.sh             # docker swarm init + create the `edge` network

# --- Cloudflare Tunnel (one-time) ---
cloudflared tunnel login
cloudflared tunnel create mediastack
# For each hostname you're routing (traefik, auth, pihole, portainer, sonarr,
# radarr, lidarr, bazarr, overseerr, lazylibrarian, grafana, prometheus,
# plex, qbittorrent, and the bare domain for homer):
cloudflared tunnel route dns mediastack <sub>.example.com
# Grab the tunnel token for init-secrets.sh next: Cloudflare Zero Trust
# dashboard -> Networks -> Tunnels -> mediastack -> Configure -> copy token
# (or `cloudflared tunnel token mediastack`)

./scripts/init-secrets.sh          # prompts for Cloudflare/NordVPN/Plex values, generates the rest

docker stack deploy -c docker-stack.yml mediastack
docker compose -f docker-compose.download.yml up -d
docker compose -f docker-compose.plex.yml up -d
```

## Authentik first boot

Can't be scripted via env vars — Authentik configures this through its own
UI after first start:

1. Visit `https://auth.example.com/if/flow/initial-setup/`, create the admin account.
2. **Applications -> Providers -> Create**: type *Proxy Provider*, mode
   *Forward auth (single application)*, external host `https://auth.example.com`.
3. **Applications -> Outposts**: use the embedded outpost, assign the
   provider you just made to it.
4. `traefik/dynamic.yml`'s `authentik` middleware already points at
   `http://authentik-server:9000/outpost.goauthentik.io/auth/traefik` —
   matches the embedded outpost's default path, nothing to change there.
5. Every service in `docker-stack.yml` already carries
   `traefik.http.routers.<name>.middlewares=authentik@file` — once the
   outpost is live, hitting any of those URLs redirects to an Authentik
   login first.

Plex is deliberately excluded from this gate (see `traefik/dynamic.yml`
comment) — its own mobile/TV apps can't complete a browser SSO redirect.
It relies on your Plex account instead.

## Directory layout expected under `/mnt/Storage/Media`

Matches what's already there — no new folders created:

```
Movies/          -> Radarr, Plex, Bazarr
TV/              -> Sonarr, Plex, Bazarr
Music/           -> Lidarr, Plex
EBooks/          -> LazyLibrarian, Plex
Audiobooks/, Documentaries/, Comics/, Podcasts/, Kids Audiobook/,
Christmas/, Pictures/, Unsorted Music/   -> Plex only (full /data mount)
```

`/mnt/Storage/Downloads` and `/mnt/Storage/Completed` (already exist) are
qBittorrent's active/completed folders, also mounted into Sonarr/Radarr/
Lidarr/LazyLibrarian so they can import finished downloads.

Heads-up, unrelated to this stack: `/mnt/Storage` is at 97% capacity
(263G free) — worth watching before this stack starts writing new config
volumes and downloads to it.

## Backups

- **Local** (`scripts/backup-local.sh`): tars every app's config volume to
  `/mnt/Storage/Backups/local/<timestamp>/`, keeps 14 days.
- **Off-site** (`scripts/backup-offsite.sh`): same volumes, via `restic` to
  Backblaze B2, encrypted. Needs `secrets/restic.env` (git-ignored) first:

  ```
  RESTIC_REPOSITORY=b2:your-bucket-name:mediastack
  RESTIC_PASSWORD=<pick a strong password — losing it loses the backup>
  B2_ACCOUNT_ID=<Backblaze application key ID>
  B2_ACCOUNT_KEY=<Backblaze application key>
  ```

Both run on a schedule via the unit files in `systemd/` (local nightly at
02:00, off-site at 03:30):

```bash
sudo cp systemd/mediastack-backup-local.{service,timer} \
        systemd/mediastack-backup-offsite.{service,timer} \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mediastack-backup-local.timer mediastack-backup-offsite.timer
```

Media itself (`/mnt/Storage/Media`) is intentionally not covered by either
backup — too large, and not ephemeral container state.

### Recovering after a host reboot

`docker-stack.yml` (Swarm) reconciles itself automatically once the daemon
comes back. The two standalone compose files don't — in particular,
`qbittorrent`'s `network_mode: service:vpn-client` doesn't reliably survive
a full daemon restart, so it can come back `Exited` even though `vpn-client`
itself started fine. `systemd/mediastack-recovery.service` re-applies both
standalone compose files (idempotent) once at boot to catch this:

```bash
sudo cp systemd/mediastack-recovery.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mediastack-recovery.service
```

## Verification checklist

- `docker stack deploy -c docker-stack.yml mediastack` — no undeclared-volume/secret errors.
- `docker service ls` — all replicas up, nothing restart-looping.
- `cloudflared tunnel info mediastack` shows connected; `ss -tlnp` on the host shows nothing new bound to 80/443.
- Any app URL redirects to Authentik login before showing the app (except Plex).
- Plex: start a transcoded stream, confirm `nvidia-smi` shows an ffmpeg process.
- `docker service update --force <service>` on something, confirm it recovers.
- Run `scripts/backup-local.sh` and `scripts/backup-offsite.sh` manually once; confirm output in `/mnt/Storage/Backups/local/` and `restic snapshots` (via `docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY restic/restic snapshots`, sourcing `secrets/restic.env` first).

## Rotating a secret

```bash
docker secret rm <name>
# update the services referencing it (docker service update, or redeploy the stack)
./scripts/init-secrets.sh   # re-creates it (skips ones that already exist otherwise)
```
