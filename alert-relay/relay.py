"""
Alertmanager -> ntfy relay. Turns Alertmanager's webhook JSON into a
readable ntfy notification.

Why this exists instead of an off-the-shelf bridge: there are five
competing community Alertmanager->ntfy bridges, none of them official,
and the best-maintained one last shipped in mid-2025. This stack has
already been burned twice by depending on an image whose upstream went
away (bubuntux/nordlynx, containrrr/watchtower). The alert path is the
one place where that failure mode is worst, because a dead relay fails
silently: alerts stop arriving and nothing tells you, which looks
exactly like "nothing is wrong". So it's ~100 lines of stdlib here
instead, with no dependencies to rot.

Deliberately stdlib-only (http.server + urllib) so this runs on a stock
python:3-alpine with nothing installed and no image to build. Mounted in
as a directory, not a single file -- single-file bind mounts go stale on
host-side edits, see the repo-wide note about that.

Config, all via env:
  NTFY_URL        base URL of the ntfy server      (default http://ntfy:80)
  NTFY_TOPIC      topic to publish to              (default alerts)
  NTFY_TOKEN_FILE path to a file holding the token (preferred)
  NTFY_TOKEN      the token inline                 (fallback, for testing)
  LISTEN_PORT     port to receive webhooks on      (default 8080)
"""
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

NTFY_URL = os.environ.get("NTFY_URL", "http://ntfy:80").rstrip("/")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "alerts")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))


def _read_token() -> str:
    """Docker secret first, inline env second.

    Same convention as the rest of the stack (postgres, redis, authentik
    all take a *_FILE). Inline NTFY_TOKEN stays supported so this can be
    run outside Swarm for testing without inventing a fake secret.
    """
    path = os.environ.get("NTFY_TOKEN_FILE")
    if path:
        try:
            return open(path).read().strip()
        except OSError as e:
            print(f"could not read NTFY_TOKEN_FILE {path}: {e}", flush=True)
            return ""
    return os.environ.get("NTFY_TOKEN", "").strip()


NTFY_TOKEN = _read_token()

# Alertmanager severity -> (ntfy priority, ntfy tag/emoji).
# ntfy priorities: 1 min, 3 default, 4 high, 5 max. Only `critical` gets
# max, which is what bypasses Android's Do Not Disturb -- that
# distinction is the whole point of having severity levels, so keep
# `warning` and `info` below the threshold that wakes anyone up.
SEVERITY = {
    "critical": (5, "rotating_light"),
    "warning": (4, "warning"),
    "info": (3, "information_source"),
}
DEFAULT_SEVERITY = (3, "grey_question")


def log(msg):
    # Unbuffered: container logs should show this immediately, and
    # python buffers stdout when it isn't a tty.
    print(msg, flush=True)


def publish(title, body, priority, tags):
    headers = {
        "Title": title,
        "Priority": str(priority),
        "Tags": ",".join(tags),
        "Content-Type": "text/plain; charset=utf-8",
    }
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"
    req = urllib.request.Request(
        f"{NTFY_URL}/{NTFY_TOPIC}",
        data=body.encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
        return True
    except urllib.error.HTTPError as e:
        # Read the body -- ntfy explains auth failures there, and a bare
        # status code is not enough to tell "bad token" from "no such
        # topic".
        log(f"ntfy rejected publish: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")
    except Exception as e:  # noqa: BLE001 -- never let a publish failure kill the server
        log(f"ntfy publish failed: {e!r}")
    return False


def render(alert):
    """One Alertmanager alert -> (title, body, priority, tags)."""
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    status = alert.get("status", "firing")
    name = labels.get("alertname", "alert")
    severity = labels.get("severity", "")

    priority, tag = SEVERITY.get(severity, DEFAULT_SEVERITY)
    if status == "resolved":
        # Resolutions are good news; they should never buzz at max
        # priority at 3am the way the firing alert was allowed to.
        priority, tag = 2, "white_check_mark"

    title = f"[{status.upper()}] {name}"
    if labels.get("instance"):
        title += f" on {labels['instance']}"

    lines = []
    if annotations.get("summary"):
        lines.append(annotations["summary"])
    if annotations.get("description"):
        lines.append(annotations["description"])
    # Surface the identifying labels, minus the ones already in the
    # title or that are pure routing noise.
    skip = {"alertname", "severity", "instance", "job"}
    extra = [f"{k}={v}" for k, v in sorted(labels.items()) if k not in skip]
    if extra:
        lines.append(" ".join(extra))
    if not lines:
        lines.append("(no summary or description on this alert)")

    return title, "\n".join(lines), priority, [tag]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler's required name
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            log(f"bad JSON from Alertmanager: {raw[:200]!r}")
            self.send_response(400)
            self.end_headers()
            return

        alerts = payload.get("alerts", [])
        sent = 0
        for alert in alerts:
            # Watchdog is the always-firing heartbeat that proves this
            # whole path works. It's routed to a dead-end receiver in
            # alertmanager.yml, but drop it here too so a routing
            # mistake can't spam the phone every 5 minutes forever.
            if alert.get("labels", {}).get("alertname") == "Watchdog":
                continue
            if publish(*render(alert)):
                sent += 1

        log(f"relayed {sent}/{len(alerts)} alert(s)")
        # Always 200 to Alertmanager. Returning an error makes it retry
        # the whole group, which duplicates the alerts that DID send.
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):  # noqa: N802
        # Healthcheck target.
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        # Silence per-request access logging; do_POST already logs what
        # matters and Alertmanager polls often enough to be noisy.
        pass


if __name__ == "__main__":
    if not NTFY_TOKEN:
        log("WARNING: no ntfy token -- publishes WILL fail, ntfy is set to deny-all")
    log(f"alert-relay listening on :{LISTEN_PORT}, publishing to {NTFY_URL}/{NTFY_TOPIC}")
    try:
        HTTPServer(("", LISTEN_PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
