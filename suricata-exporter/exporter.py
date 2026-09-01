#!/usr/bin/env python3
"""Expose Suricata's own stats to Prometheus, so the IDS can be monitored.

WHY THIS EXISTS RATHER THAN A LIVENESS CHECK

Suricata will run perfectly happily while detecting nothing. It did
exactly that here: suricata-update wrote 68619 rules into a directory the
Suricata process could not read, and the engine came up, logged flows,
answered health checks and loaded ZERO signatures. Anything checking
"is the container running" would have reported green indefinitely.

So the useful signals are not liveness, they are:
  rules_loaded      -> 0 means blind, however healthy it looks
  kernel_packets    -> flat means it is not seeing the wire
  kernel_drops      -> climbing means it is overloaded and missing traffic
  stats age         -> stale means the process is wedged

No dependencies: stdlib only, so a stock python image runs it with
nothing installed, matching alert-relay. There is no image to build and
no registry to depend on.
"""
import json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer

EVE = os.environ.get("EVE_PATH", "/var/log/suricata/eve.json")
PORT = int(os.environ.get("PORT", "9101"))
# Suricata writes a stats event every 8s by default; well past that means
# the process is wedged even if it is still resident.
STALE_AFTER = int(os.environ.get("STALE_AFTER", "120"))
TAIL_BYTES = 512 * 1024


def last_stats():
    """Newest stats event, read backwards from the tail of eve.json.

    Stateless on purpose: reading a window of the tail on each scrape
    means no file handle to lose across log rotation, and no position to
    get wrong after a restart.
    """
    try:
        size = os.path.getsize(EVE)
        with open(EVE, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            chunk = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    for line in reversed(chunk.splitlines()):
        if '"event_type":"stats"' not in line:
            continue
        try:
            return json.loads(line)
        except ValueError:
            continue          # a torn final line is normal while tailing
    return None


def render():
    out = []

    def m(name, help_, typ, value, labels=""):
        out.append(f"# HELP {name} {help_}")
        out.append(f"# TYPE {name} {typ}")
        out.append(f"{name}{labels} {value}")

    ev = last_stats()
    if ev is None:
        m("suricata_up", "1 if a fresh stats event was found", "gauge", 0)
        return "\n".join(out) + "\n"

    s = ev.get("stats", {})
    age = STALE_AFTER + 1
    ts = ev.get("timestamp")
    if ts:
        try:
            from datetime import datetime
            age = max(0, time.time() - datetime.fromisoformat(ts).timestamp())
        except Exception:
            pass

    m("suricata_up", "1 if stats are fresh", "gauge", 1 if age <= STALE_AFTER else 0)
    m("suricata_stats_age_seconds", "Age of the newest stats event", "gauge", round(age, 1))
    m("suricata_uptime_seconds", "Engine uptime", "gauge", s.get("uptime", 0))

    cap = s.get("capture", {})
    m("suricata_kernel_packets_total", "Packets seen by the capture method",
      "counter", cap.get("kernel_packets", 0))
    m("suricata_kernel_drops_total", "Packets dropped before inspection",
      "counter", cap.get("kernel_drops", 0))

    det = s.get("detect", {})
    engines = det.get("engines") or [{}]
    eng = engines[0]
    # The one that matters most: a running engine with no rules is blind.
    m("suricata_rules_loaded", "Signatures currently loaded", "gauge",
      eng.get("rules_loaded", 0))
    m("suricata_rules_failed", "Signatures that failed to load", "gauge",
      eng.get("rules_failed", 0))
    m("suricata_alerts_total", "Alerts raised since start", "counter",
      det.get("alert", 0))

    flow = s.get("flow", {})
    m("suricata_flow_memuse_bytes", "Flow table memory in use", "gauge",
      flow.get("memuse", 0))
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/"):
            self.send_response(404); self.end_headers(); return
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass          # one line per scrape is noise, not information


if __name__ == "__main__":
    print(f"suricata-exporter on :{PORT}, reading {EVE}", flush=True)
    HTTPServer(("", PORT), Handler).serve_forever()
