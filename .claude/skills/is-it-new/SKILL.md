---
name: is-it-new
description: Check whether Traefik/Authentik (the deliberately pinned services in this stack) are behind the latest release, and if so, walk through the release notes to make a go/no-go call together. Use when the user asks to check for updates, mentions a new version, or invokes "is it new".
---

# Is it new?

C2MediaServerStack pins Traefik and Authentik explicitly (see the
`com.centurylinklabs.watchtower.enable=false` labels and surrounding
comments in `docker-stack.yml`) instead of floating them on `:latest` like
everything else — both gate access to the whole stack, and Authentik in
particular has a hard requirement to upgrade through every intermediate
major release sequentially, no skipping. This skill is the recurring
"check, then decide together" loop for those two services.

## Steps

1. Run `scripts/check-pinned-versions.sh` from the repo root. It's
   read-only — reports current pin vs latest release for each, and for
   Authentik, lists every sequential hop required (never assume you can
   jump straight to latest).

2. If both say "Up to date," report that plainly and stop — nothing else
   to do.

3. If something's behind, don't just report the version number. Fetch the
   actual release notes for each candidate version (the script prints
   direct URLs) and read them for:
   - Breaking changes or required manual migration steps (not routine
     auto-applied DB migrations — those are always fine)
   - Whether the release is very recent (< ~1-2 weeks old) — if so, lean
     towards waiting for an early-bug-fix patch release before adopting
   - Anything relevant to this stack specifically: Authentik's proxy
     providers / outposts / blueprints, or Traefik's swarm provider /
     forwardAuth middleware behavior

4. Present a short pros/cons summary per candidate version and ask the
   user for a go/no-go — don't decide unilaterally, this is exactly the
   kind of call this skill exists to make *together*.

5. If it's a go, execute the same verification loop used for the last
   real upgrade (see git log / CLAUDE.md context on the 2024.10 -> 2026.8
   Authentik march for the full pattern):
   - Take a fresh `pg_dump` before touching Authentik (cheap, seconds,
     non-negotiable given the blast radius)
   - Bump one hop at a time for Authentik; a single bump for Traefik
   - After each hop: wait for the service to reach `Running`, check
     server (and worker, for Authentik) logs for real errors (exclude
     known-benign noise like `record not found` on stale session
     lookups or the `gunicorn.error` logger namespace), then hit
     `/-/health/live/` and a couple of real Traefik-routed app URLs
     (one domain-level, one admin-restricted) before moving to the next
     hop
   - Traefik getting recreated stalls `cloudflared`'s cached DNS
     resolution of it — restart `cloudflared` (`docker service update
     --force mediastack_cloudflared`) after any Traefik bump, whether or
     not you've seen it break yet

6. Commit with a clear message explaining what moved and why, same as
   every other change in this repo.
