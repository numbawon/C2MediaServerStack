"""
Crafty Controller -> router port-forward relay.

Why this exists: Minecraft's protocol is raw TCP, so Authentik cannot gate
it the way it gates everything else in this stack, and the router's SSH
server (dropbear) turned out not to enforce authorized_keys `command=`
restrictions at all -- confirmed the hard way, an "attacker" command ran
straight through despite a forced-command entry. So Crafty never gets a
router credential of its own. Instead it makes a plain, bearer-token HTTP
call here, and this relay is the only thing that holds the actual SSH key
and is the only place the port-range rule is enforced (also re-checked by
router/minecraft-port-toggle.sh itself on the router end -- belt and
suspenders, not a single point of trust).

The key this relay uses is authorized the same way router-exporter.py's
own key is: appended to the `sshd_authkeys` nvram variable (the router's
real, WebUI-integrated mechanism), not /jffs/.ssh/authorized_keys --
confirmed the hard way that dropbear on this router does not read that
file at all despite it looking like a normal authorized_keys location.
`service restart_sshd` is what actually regenerates
~numbawon/.ssh/authorized_keys from the nvram value; a bare `nvram
commit` alone does not.

Deliberately stdlib-only (http.server + subprocess), same reasoning as
alert-relay: no dependency to rot, runs on stock python:3-alpine (plus
openssh-client, added at container start -- see docker-stack.yml).
Mounted in as a directory, not a single file, same reason as everywhere
else in this repo: single-file bind mounts go stale on host-side edits.

Config, all via env:
  ROUTER_HOST       router's LAN address                 (default 192.168.50.1)
  ROUTER_USER       SSH user on the router                (default numbawon)
  ROUTER_KEY_FILE   path to the private key for that user (default /run/secrets/minecraft_router_key)
  TOKEN_FILE        path to the bearer token this relay requires (default /run/secrets/minecraft_relay_token)
  LISTEN_PORT       port to receive requests on            (default 8080)
  MIN_PORT/MAX_PORT the same range router/minecraft-port-toggle.sh accepts (default 25565/25580)

POST /toggle, JSON body {"action": "open"|"close", "port": 25565}
Header: Authorization: Bearer <token>
"""
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROUTER_HOST = os.environ.get("ROUTER_HOST", "192.168.50.1")
ROUTER_USER = os.environ.get("ROUTER_USER", "numbawon")
ROUTER_KEY_FILE = os.environ.get("ROUTER_KEY_FILE", "/run/secrets/minecraft_router_key")
TOKEN_FILE = os.environ.get("TOKEN_FILE", "/run/secrets/minecraft_relay_token")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
MIN_PORT = int(os.environ.get("MIN_PORT", "25565"))
MAX_PORT = int(os.environ.get("MAX_PORT", "25580"))


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


TOKEN = _read(TOKEN_FILE)

# Docker mounts secrets read-only at 0444 (world-readable), and ssh flatly
# refuses to use a private key file with those permissions -- confirmed:
# "Permission denied (publickey)" with no hint it was a mode problem, not
# a wrong-key problem. Swarm secret mounts cannot be chmod'd in place
# (they're a special read-only mount, not a normal file), so the key gets
# copied to a real, writable path once at startup instead.
ROUTER_KEY_RUNTIME = "/tmp/router_key"
with open(ROUTER_KEY_FILE, "r", encoding="utf-8") as src, \
     open(ROUTER_KEY_RUNTIME, "w", encoding="utf-8") as dst:
    dst.write(src.read())
os.chmod(ROUTER_KEY_RUNTIME, 0o600)


def _toggle(action: str, port: int) -> tuple[bool, str]:
    cmd = [
        "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=8", "-i", ROUTER_KEY_RUNTIME,
        f"{ROUTER_USER}@{ROUTER_HOST}",
        "/jffs/scripts/minecraft-port-toggle.sh", action, str(port),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        return False, "timed out reaching the router"
    if r.returncode != 0:
        return False, (r.stderr or r.stdout or "non-zero exit, no output").strip()
    return True, (r.stdout or "ok").strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Default logs to stderr with client address; keep that, it is
        # the only audit trail of who asked to open/close a router port.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _reply(self, code: int, body: dict):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/toggle":
            self._reply(404, {"error": "not found"})
            return

        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self._reply(401, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._reply(400, {"error": "bad json"})
            return

        action = data.get("action")
        port = data.get("port")
        if action not in ("open", "close"):
            self._reply(400, {"error": "action must be 'open' or 'close'"})
            return
        if not isinstance(port, int) or not (MIN_PORT <= port <= MAX_PORT):
            self._reply(400, {"error": f"port must be an integer {MIN_PORT}-{MAX_PORT}"})
            return

        ok, detail = _toggle(action, port)
        self._reply(200 if ok else 502, {"ok": ok, "detail": detail})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
