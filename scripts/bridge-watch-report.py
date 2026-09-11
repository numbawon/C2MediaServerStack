#!/usr/bin/env python3
"""Summarise the filtering bridge's IDS watch, optionally as a push.

Written for the five day observation period before switching the bridge
from IDS to IPS, but it is not single-use: run it any time to get the
current picture in one screen.

    python3 scripts/bridge-watch-report.py             # print
    python3 scripts/bridge-watch-report.py --notify    # print and push

Both Prometheus and alert-relay live on the `mediastack_internal`
overlay, which is NOT attachable, so the prowlarr-metrics trick of
`docker run --network ...` does not work here. Instead this runs wget
inside the Prometheus container, which is already a member of that
network and already ships wget. That also means no ntfy token ever has
to leave its Docker secret: alert-relay holds it and this only speaks
Alertmanager's webhook format at the relay.

Why a report rather than another alert rule: the rules in
prometheus/rules/bridge.yml fire when something is wrong. This answers
"should IPS go on", which needs the shape of five days, not the value of
one instant, and that is a question you ask on purpose rather than one
that should page you.
"""
import argparse
import json
import subprocess
import sys

# How long the observation period runs. A verdict before this is
# reported as progress, never as a GO.
WATCH_DAYS = 5

RELAY = "http://alert-relay:8080/"
PROM = "http://127.0.0.1:9090/api/v1/query"

DROP_RATE = """
100 * rate(mediastack_bridge_stat{{stat="capture.kernel_drops"}}[{w}])
    / ignoring(stat) clamp_min(
        rate(mediastack_bridge_stat{{stat="capture.kernel_packets"}}[{w}]), 1)
"""


def prom_container():
    p = subprocess.run(["docker", "ps", "-q", "-f", "name=mediastack_prometheus"],
                       capture_output=True, text=True)
    cid = p.stdout.split()
    if not cid:
        print("prometheus container not running", file=sys.stderr)
        sys.exit(1)
    return cid[0]


def q(cid, expr):
    """One instant query. Returns the first sample's value, or None.

    POST, not GET: the drop-rate expression contains `/` and `,` and a
    hand-rolled GET query string mangled it into an empty result once
    already, which is indistinguishable from "no data" at a glance.
    """
    p = subprocess.run(
        ["docker", "exec", cid, "wget", "-qO-", "--post-data=query=" + expr, PROM],
        capture_output=True, text=True)
    try:
        r = json.loads(p.stdout)["data"]["result"]
    except (ValueError, KeyError):
        return None
    return float(r[0]["value"][1]) if r else None


def qall(cid, expr):
    p = subprocess.run(
        ["docker", "exec", cid, "wget", "-qO-", "--post-data=query=" + expr, PROM],
        capture_output=True, text=True)
    try:
        return json.loads(p.stdout)["data"]["result"]
    except (ValueError, KeyError):
        return []


def fmt(v, suffix="", nd=2):
    return "n/a" if v is None else "%.*f%s" % (nd, v, suffix)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notify", action="store_true",
                    help="also push through alert-relay to ntfy")
    args = ap.parse_args()
    cid = prom_container()

    up = q(cid, "mediastack_bridge_uptime_seconds")
    reach = q(cid, "mediastack_bridge_reachable")
    suri = q(cid, "mediastack_bridge_suricata_up")
    now = q(cid, DROP_RATE.format(w="1h"))
    d6 = q(cid, DROP_RATE.format(w="6h"))
    d24 = q(cid, DROP_RATE.format(w="24h"))
    worst = q(cid, "max_over_time(("
                   + DROP_RATE.format(w="15m").strip() + ")[24h:5m])")
    pkts = q(cid, 'rate(mediastack_bridge_stat{stat="capture.kernel_packets"}[1h])')
    mem = q(cid, 'mediastack_bridge_stat{stat="memcap_pressure_max"}')
    alerts24 = q(cid, 'increase(mediastack_bridge_stat{stat="detect.alert"}[24h])')
    # A restart zeroes every counter, so a watch that spans one is not a
    # five day watch. resets() counts them directly.
    restarts = q(cid, "resets(mediastack_bridge_uptime_seconds[24h])")

    days = up / 86400.0 if up else 0.0
    lines = [
        "Suricata up %.1f days, reachable=%s running=%s" % (
            days, int(reach or 0), int(suri or 0)),
        "Drop rate  1h %s | 6h %s | 24h %s" % (
            fmt(now, "%"), fmt(d6, "%"), fmt(d24, "%")),
        "Worst 15m window in 24h: %s" % fmt(worst, "%"),
        "Throughput %s pkt/s, memcap peak %s%%" % (
            fmt(pkts, "", 0), fmt(mem, "", 0)),
        "IDS alerts in 24h: %s, Suricata restarts: %s" % (
            fmt(alerts24, "", 0), fmt(restarts, "", 0)),
    ]

    sigs = qall(cid, "topk(5, mediastack_bridge_alerts)")
    if sigs:
        lines.append("Top signatures:")
        for s in sigs:
            lines.append("  %sx %s" % (
                s["value"][1], s["metric"].get("signature", "?")[:60]))

    # The actual recommendation, stated rather than left as an exercise.
    if restarts and restarts > 0:
        verdict = ("HOLD: Suricata restarted during the window, so the "
                   "counters do not cover a continuous run. Restart the clock.")
    elif worst is None or d24 is None:
        verdict = "HOLD: not enough data yet to judge."
    elif days < WATCH_DAYS:
        # Low numbers over a short window are not evidence of stability,
        # they are evidence of a short window. Without this the report
        # happily returned GO on two hours of data.
        verdict = ("HOLD: %.1f of %g days of continuous data so far. "
                   "Numbers look %s, but the watch is not finished."
                   % (days, WATCH_DAYS,
                      "clean" if (worst <= 5 and d24 <= 5) else "rough"))
    elif worst > 20:
        verdict = ("HOLD: peaks above 20%. In IPS those packets become "
                   "dropped connections, not missed alerts.")
    elif d24 > 5:
        verdict = ("HOLD: sustained loss above 5%. Raise capture buffers "
                   "before enabling IPS.")
    elif worst > 5:
        verdict = ("CAUTION: steady state is fine but it spikes. Bursty "
                   "loss usually means the capture buffer is too small for "
                   "peaks, which is cheaper to fix than it is to debug "
                   "after IPS is on.")
    else:
        verdict = "GO: sustained and peak loss both low across the window."
    lines.append("")
    lines.append(verdict)

    body = "\n".join(lines)
    print(body)

    if not args.notify:
        return 0

    payload = json.dumps({"alerts": [{
        "status": "firing",
        "labels": {"alertname": "BridgeWatchReview", "severity": "warning",
                   "service": "bridge"},
        "annotations": {"summary": "Bridge IDS watch review", "description": body},
    }]})
    p = subprocess.run(
        ["docker", "exec", cid, "wget", "-qO-", "--header=Content-Type: application/json",
         "--post-data=" + payload, RELAY],
        capture_output=True, text=True)
    if p.returncode != 0:
        print("push failed: %s" % (p.stderr.strip() or "wget error"), file=sys.stderr)
        return 1
    print("\npushed via alert-relay")
    return 0


if __name__ == "__main__":
    sys.exit(main())
