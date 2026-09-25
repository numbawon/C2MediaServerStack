"""
Crafty server status -> router port-lever watcher.

Why this exists: Crafty has no usable start/stop hook. Its webhook
feature is hard-coded to Discord/Slack/Mattermost/Teams payload shapes
(confirmed by reading Crafty's own source, app/classes/web/webhooks/*.py --
no generic/custom HTTP type exists), so it can't carry the relay's bearer
token. Its task scheduler is time-based only, no start/stop trigger. So
instead of a push-based hook, this polls Crafty's own status endpoint and
calls minecraft-router-relay on any observed state change.

Deliberately watches state rather than wrapping the server's own execution
command: it never touches how Crafty tracks the server's PID or forwards
console input, and it keeps working across Crafty updates that might
change that internal behavior.

Crafty's GET /api/v2/servers/status is unauthenticated by design (Crafty's
own source has no authenticate_user() call in that handler) but only
returns servers with "Show Status" enabled in that server's settings --
enable it for any server that should drive the router lever. It does not
include the server's game port, so SERVER_PORT_MAP supplies that mapping
by hand; low server churn (a handful of Minecraft servers at most) makes
this simpler than adding a second, authenticated API call just to look up
a port that rarely changes.

On every poll, any server whose observed running-state differs from what
was last successfully pushed to the relay gets pushed again -- including
on the watcher's own restart, when the last-known state is unknown. This
makes it self-healing (a missed transition during a watcher restart is
corrected on the next successful poll) and safe to over-call, since
router/minecraft-port-toggle.sh's own iptables check is idempotent.

Deliberately stdlib-only, same reasoning as minecraft-router-relay's own
relay.py: no dependency to rot.

Config, all via env:
  CRAFTY_URL        base URL for Crafty's API           (default https://crafty:8443)
  RELAY_URL         minecraft-router-relay's /toggle URL (default http://minecraft-router-relay:8080/toggle)
  RELAY_TOKEN_FILE  path to the relay's bearer token     (default /run/secrets/minecraft_relay_token)
  SERVER_PORT_MAP   "server_id:port,server_id:port,..."  (default empty, watcher idles)
  POLL_INTERVAL     seconds between polls                (default 15)
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

CRAFTY_URL = os.environ.get("CRAFTY_URL", "https://crafty:8443").rstrip("/")
RELAY_URL = os.environ.get("RELAY_URL", "http://minecraft-router-relay:8080/toggle")
RELAY_TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/run/secrets/minecraft_relay_token")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "15"))

_raw_map = os.environ.get("SERVER_PORT_MAP", "").strip()

SERVER_PORT_MAP = {}
for pair in _raw_map.split(","):
    pair = pair.strip()
    if not pair:
        continue
    server_id, port = pair.rsplit(":", 1)
    SERVER_PORT_MAP[server_id.strip()] = int(port.strip())

with open(RELAY_TOKEN_FILE, "r", encoding="utf-8") as f:
    RELAY_TOKEN = f.read().strip()

# Crafty's cert is self-signed here (same reasoning as Traefik's
# serversTransport for the crafty.<domain> route: the client that matters
# never sees this cert, and this connection never leaves the edge overlay).
_INSECURE_CTX = ssl.create_default_context()
_INSECURE_CTX.check_hostname = False
_INSECURE_CTX.verify_mode = ssl.CERT_NONE

# None = unknown (forces a push on first successful observation, so a
# watcher restart always resyncs the real port state instead of assuming).
last_known_running = {server_id: None for server_id in SERVER_PORT_MAP}


def fetch_status() -> dict:
    req = urllib.request.Request(f"{CRAFTY_URL}/api/v2/servers/status")
    with urllib.request.urlopen(req, timeout=10, context=_INSECURE_CTX) as resp:
        body = json.loads(resp.read())
    return {str(s["id"]): bool(s["running"]) for s in body.get("data", [])}


def push_toggle(server_id: str, running: bool) -> bool:
    action = "open" if running else "close"
    port = SERVER_PORT_MAP[server_id]
    payload = json.dumps({"action": action, "port": port}).encode("utf-8")
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
        print(f"[{server_id}] relay call failed ({action}, port {port}): {e}", file=sys.stderr)
        return False
    if ok:
        print(f"[{server_id}] port {port} -> {action}")
    else:
        print(f"[{server_id}] relay rejected {action} for port {port}", file=sys.stderr)
    return ok


def poll_once():
    try:
        status = fetch_status()
    except (urllib.error.URLError, json.JSONDecodeError, KeyError) as e:
        print(f"could not reach Crafty's status endpoint: {e}", file=sys.stderr)
        return

    for server_id in SERVER_PORT_MAP:
        if server_id not in status:
            # Show Status is likely off for this server -- warn once per
            # poll rather than staying silent about a misconfiguration.
            print(f"[{server_id}] not present in Crafty's status response "
                  f"(enable \"Show Status\" on this server)", file=sys.stderr)
            continue
        running = status[server_id]
        if running != last_known_running[server_id]:
            if push_toggle(server_id, running):
                last_known_running[server_id] = running


if __name__ == "__main__":
    if not SERVER_PORT_MAP:
        print("SERVER_PORT_MAP is empty -- idling. Set it once a real "
              "server exists (see .env's own comment above that var).")
    else:
        print(f"watching {len(SERVER_PORT_MAP)} server(s), polling every {POLL_INTERVAL}s")
    while True:
        if SERVER_PORT_MAP:
            poll_once()
        time.sleep(POLL_INTERVAL)
