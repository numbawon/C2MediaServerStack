"""
Crafty server status -> router port-lever watcher.

Why this exists: Crafty has no usable start/stop hook. Its webhook
feature is hard-coded to Discord/Slack/Mattermost/Teams payload shapes
(confirmed by reading Crafty's own source, app/classes/web/webhooks/*.py --
no generic/custom HTTP type exists), so it can't carry the relay's bearer
token. Its task scheduler is time-based only, no start/stop trigger. So
instead of a push-based hook, this polls Crafty's own API and calls
minecraft-router-relay on any observed state change.

Deliberately watches state rather than wrapping the server's own execution
command: it never touches how Crafty tracks the server's PID or forwards
console input, and it keeps working across Crafty updates that might
change that internal behavior.

Fully auto-discovering, on purpose -- "in case I'm not there to manage"
was the actual ask. Two Crafty API calls per known server:
  - GET /api/v2/servers/status (unauthenticated by design in Crafty's own
    source) lists every server with "Show Status" enabled in its own
    settings, with id + running. This IS the discovery mechanism and the
    user-facing on/off switch for which servers drive the lever -- no
    watcher-side list to hand-maintain.
  - GET /api/v2/servers/{id}/stats (authenticated, needs CRAFTY_API_TOKEN)
    includes the server's real configured port (ServerStats.server_port
    in Crafty's own model). Fetched once per server and cached -- server
    ports don't change often, and this is a low-server-count setup.
Protocol isn't exposed by either call, so it's derived from the port
itself against the same three-entry allow-list minecraft-router-relay and
router/minecraft-port-toggle.sh both enforce. Keep all three in sync by
hand if a game type is ever added.

On every poll, any known server whose observed running-state differs from
what was last successfully pushed to the relay gets pushed again --
including on the watcher's own restart, when the last-known state is
unknown. This makes it self-healing (a missed transition during a watcher
restart is corrected on the next successful poll) and safe to over-call,
since router/minecraft-port-toggle.sh's own iptables check is idempotent.

Deliberately stdlib-only, same reasoning as minecraft-router-relay's own
relay.py: no dependency to rot.

Config, all via env:
  CRAFTY_URL          base URL for Crafty's API            (default https://crafty:8443)
  CRAFTY_API_TOKEN_FILE  path to a Crafty API token          (default /run/secrets/crafty_api_token)
  RELAY_URL           minecraft-router-relay's /toggle URL (default http://minecraft-router-relay:8080/toggle)
  RELAY_TOKEN_FILE    path to the relay's bearer token     (default /run/secrets/minecraft_relay_token)
  POLL_INTERVAL       seconds between polls                (default 15)

The Crafty API token needs to belong to a user with access to every
server that should drive the lever (create a dedicated low-privilege
Crafty user for this rather than reusing an admin's own token -- see the
repo README's Minecraft section for the exact steps).
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

CRAFTY_URL = os.environ.get("CRAFTY_URL", "https://crafty:8443").rstrip("/")
CRAFTY_API_TOKEN_FILE = os.environ.get("CRAFTY_API_TOKEN_FILE", "/run/secrets/crafty_api_token")
RELAY_URL = os.environ.get("RELAY_URL", "http://minecraft-router-relay:8080/toggle")
RELAY_TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/run/secrets/minecraft_relay_token")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "15"))


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


CRAFTY_API_TOKEN = _read(CRAFTY_API_TOKEN_FILE)
RELAY_TOKEN = _read(RELAY_TOKEN_FILE)

# Crafty's cert is self-signed here (same reasoning as Traefik's
# serversTransport for the crafty.<domain> route: the client that matters
# never sees this cert, and this connection never leaves the edge overlay).
_INSECURE_CTX = ssl.create_default_context()
_INSECURE_CTX.check_hostname = False
_INSECURE_CTX.verify_mode = ssl.CERT_NONE

# Mirrors minecraft-router-relay's own allow-list exactly -- see that
# file's header for why it's a fixed table rather than a wide range.
def _protocol_for_port(port: int) -> str | None:
    if 25565 <= port <= 25580:
        return "tcp"
    if port in (19132, 5520):
        return "udp"
    return None


port_cache: dict[str, int] = {}          # server_id -> port, filled once
last_known_running: dict[str, bool] = {}  # server_id -> last state pushed


def _crafty_get(path: str, authed: bool) -> dict:
    req = urllib.request.Request(f"{CRAFTY_URL}{path}")
    if authed:
        req.add_header("Authorization", f"Bearer {CRAFTY_API_TOKEN}")
    with urllib.request.urlopen(req, timeout=10, context=_INSECURE_CTX) as resp:
        return json.loads(resp.read())


def fetch_status() -> dict:
    body = _crafty_get("/api/v2/servers/status", authed=False)
    return {str(s["id"]): bool(s["running"]) for s in body.get("data", [])}


def fetch_port(server_id: str) -> int | None:
    try:
        body = _crafty_get(f"/api/v2/servers/{server_id}/stats", authed=True)
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"[{server_id}] could not fetch stats for port lookup: {e}", file=sys.stderr)
        return None
    port = (body.get("data") or {}).get("server_port")
    return int(port) if port else None


def push_toggle(server_id: str, running: bool, port: int, protocol: str) -> bool:
    action = "open" if running else "close"
    payload = json.dumps({"action": action, "port": port, "protocol": protocol}).encode("utf-8")
    req = urllib.request.Request(
        RELAY_URL,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {RELAY_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            ok = 200 <= resp.status < 300
    except urllib.error.URLError as e:
        print(f"[{server_id}] relay call failed ({action}, {protocol}/{port}): {e}", file=sys.stderr)
        return False
    if ok:
        print(f"[{server_id}] {protocol}/{port} -> {action}")
    else:
        print(f"[{server_id}] relay rejected {action} for {protocol}/{port}", file=sys.stderr)
    return ok


def poll_once():
    try:
        status = fetch_status()
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"could not reach Crafty's status endpoint: {e}", file=sys.stderr)
        return

    for server_id, running in status.items():
        if server_id not in port_cache:
            port = fetch_port(server_id)
            if port is None:
                continue  # try again next poll
            protocol = _protocol_for_port(port)
            if protocol is None:
                print(f"[{server_id}] port {port} matches no known game type, "
                      f"skipping -- add it to the allow-list in relay.py, "
                      f"minecraft-port-toggle.sh, and watcher.py if this is "
                      f"real", file=sys.stderr)
                continue
            port_cache[server_id] = port
            print(f"[{server_id}] discovered {protocol}/{port}")

        port = port_cache[server_id]
        protocol = _protocol_for_port(port)
        if running != last_known_running.get(server_id):
            if push_toggle(server_id, running, port, protocol):
                last_known_running[server_id] = running


if __name__ == "__main__":
    print(f"watching Crafty's status endpoint every {POLL_INTERVAL}s "
          f"(servers need \"Show Status\" enabled to be seen at all)")
    while True:
        poll_once()
        time.sleep(POLL_INTERVAL)
