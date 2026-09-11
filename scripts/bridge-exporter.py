#!/usr/bin/env python3
"""Export Suricata health from the transparent filtering bridge.

WHY THIS EXISTS SEPARATELY FROM suricata-exporter

scripts/suricata-exporter.py reads the Suricata running in THIS stack, on
this host's own NIC, over a local unix socket. The bridge at
COMMON_BRIDGE_HOST is a different machine entirely -- OPNsense on FreeBSD,
Suricata driven by OPNsense's own config -- reachable only over SSH. Same
software, different box, different transport, so it gets its own collector
rather than a flag on that one.

WHAT IT IS FOR, SPECIFICALLY

The bridge runs Suricata in IDS mode (pcap capture, not inline). The
question this answers is whether it is safe to switch it to IPS, where a
dropped packet stops being a missed alert and starts being a broken
connection for the household.

Three counters decide that, and none of them is the alert count:

  capture.kernel_drops    packets Suricata never saw. In IDS that is a
                          blind spot; in IPS the same pressure becomes
                          latency and stalled sessions.
  memcap_pressure         how close the flow/stream tables are to their
                          ceiling. Sustained pressure means the next
                          traffic spike drops flows.
  tcp.reassembly_gap      streams it could not reassemble, which is the
                          downstream symptom of the first two.

Drops are reported as a COUNTER, not a percentage. A percentage hides
whether loss is a one-off burst at startup -- which is normal and
harmless -- or continuous. On first look this bridge had 151,961 drops
frozen while packets climbed past 5M: a burst, not a leak. Grafana can
compute a rate from a counter; it cannot recover the shape from an
average.

Read-only. Never writes to the bridge, never restarts anything.

Run by systemd/mediastack-bridge-exporter.timer.
"""
import json
import os
import re
import subprocess
import sys
import time

TEXTFILE_VOLUME = "node_exporter_textfile"
METRIC_FILE = "bridge.prom"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
       "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5"]

# Counters worth a permanent series. Suricata emits several hundred; most
# are zero forever and each one costs a series in Prometheus for good.
# These are the ones that answer "is it keeping up" and "is it seeing
# everything".
WANTED = {
    "capture.kernel_packets", "capture.kernel_drops", "capture.kernel_ifdrops",
    "decoder.pkts", "decoder.bytes", "decoder.invalid",
    "flow.memcap", "flow.tcp", "flow.udp", "flow.icmpv4", "flow.icmpv6",
    "tcp.memcap_drop", "tcp.reassembly_gap", "tcp.invalid_checksum",
    "tcp.overlap", "tcp.ssn_memcap_drop",
    "defrag.max_frag_hits",
    "detect.alert", "detect.alerts_suppressed",
    "memcap_pressure", "memcap_pressure_max",
    "app_layer.error.tls.gap", "app_layer.error.http.gap",
}

# Suricata prints uptime on the "Date:" header of each stats block, not
# as a pipe-delimited counter, so it can never match WANTED. It is worth
# having on its own: every counter above resets to zero when Suricata
# restarts, and without uptime a restart is indistinguishable from a
# quiet period. stats.log rotates daily, so the bridge keeps no history
# of its own to reconstruct one from.
UPTIME_RE = re.compile(r"uptime:\s*(\d+)d,\s*(\d+)h\s*(\d+)m\s*(\d+)s")

# One round trip. stats.log is append-only with a block per interval, so
# the LAST block is current; earlier blocks are history Prometheus already
# has. eve.json is tailed rather than read whole -- it reached 1.9 MB in
# two hours here and would be far larger over the five-day watch.
# sudo on every read, not just the log files: FreeBSD hides other users'
# processes from pgrep by default (security.bsd.see_other_uids), so an
# unprivileged pgrep returns nothing and Suricata looks stopped while it
# is running perfectly well.
#
# stats.log is tailed flat rather than split into blocks. It is append-only
# with one block per interval, so the LAST value of each counter is the
# current one, and a dict assignment in the parser gives that for free.
# An earlier version tried to extract the final block with awk and silently
# produced nothing when the tail landed mid-block.
PROBE = r"""
echo "PID $(sudo pgrep -f 'suricata .*--pcap' 2>/dev/null | head -1)"
echo "@@SECTION@@STATS"
sudo tail -600 /var/log/suricata/stats.log 2>/dev/null
echo "@@SECTION@@ALERTS"
sudo tail -c 400000 /var/log/suricata/eve.json 2>/dev/null | grep '"event_type":"alert"' | tail -300
"""


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def main():
    started = time.time()
    host = os.environ.get("COMMON_BRIDGE_HOST")
    if not host:
        print("COMMON_BRIDGE_HOST not set", file=sys.stderr)
        return 1

    try:
        p = subprocess.run(SSH + [host, "sh"], input=PROBE, text=True,
                           capture_output=True, timeout=90)
        out = p.stdout if p.returncode == 0 else ""
    except (subprocess.SubprocessError, OSError) as e:
        print("ssh to %s failed: %s" % (host, e), file=sys.stderr)
        out = ""

    lines = [
        "# HELP mediastack_bridge_reachable Whether the bridge answered over SSH.",
        "# TYPE mediastack_bridge_reachable gauge",
        "# HELP mediastack_bridge_suricata_up Whether Suricata is running on the bridge.",
        "# TYPE mediastack_bridge_suricata_up gauge",
        "# HELP mediastack_bridge_stat Selected Suricata counters. Counters, not rates -- see the module docstring.",
        "# TYPE mediastack_bridge_stat gauge",
        "# HELP mediastack_bridge_alerts Alerts seen in the tail of eve.json, by signature and severity.",
        "# TYPE mediastack_bridge_alerts gauge",
        "# HELP mediastack_bridge_uptime_seconds Suricata uptime. Drops to near zero on restart, which also zeroes every counter above.",
        "# TYPE mediastack_bridge_uptime_seconds gauge",
        "# HELP mediastack_bridge_exporter_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_bridge_exporter_last_run_timestamp_seconds gauge",
    ]

    if not out:
        lines.append('mediastack_bridge_reachable{host="%s"} 0' % esc(host))
        lines.append('mediastack_bridge_suricata_up{host="%s"} 0' % esc(host))
    else:
        lines.append('mediastack_bridge_reachable{host="%s"} 1' % esc(host))
        section = None
        stats, alerts = {}, {}
        suri_up = 0
        uptime = None
        for ln in out.splitlines():
            if ln.startswith("PID "):
                suri_up = 1 if ln[4:].strip() else 0
                continue
            # Exact sentinel, not a startswith("---") test. stats.log is
            # full of dashed separator lines, so a loose marker check
            # silently resets the section partway through and discards
            # every counter after the first separator -- which is where
            # capture.kernel_packets and kernel_drops live.
            if ln.startswith("@@SECTION@@"):
                section = ln[len("@@SECTION@@"):].strip()
                continue
            if section == "STATS" and ln.startswith("Date:"):
                m = UPTIME_RE.search(ln)
                if m:
                    d, h, mi, sec = (int(g) for g in m.groups())
                    uptime = d * 86400 + h * 3600 + mi * 60 + sec
                continue
            if section == "STATS" and "|" in ln:
                parts = [c.strip() for c in ln.split("|")]
                if len(parts) >= 3 and parts[0] in WANTED:
                    try:
                        stats[parts[0]] = float(parts[-1])
                    except ValueError:
                        pass
            elif section == "ALERTS" and ln.startswith("{"):
                try:
                    a = json.loads(ln).get("alert") or {}
                except ValueError:
                    continue
                key = (a.get("signature") or "?", a.get("severity", 0),
                       a.get("category") or "?")
                alerts[key] = alerts.get(key, 0) + 1

        lines.append('mediastack_bridge_suricata_up{host="%s"} %d' % (esc(host), suri_up))
        if uptime is not None:
            lines.append('mediastack_bridge_uptime_seconds{host="%s"} %d'
                         % (esc(host), uptime))
        for name, val in sorted(stats.items()):
            lines.append('mediastack_bridge_stat{host="%s",stat="%s"} %g'
                         % (esc(host), esc(name), val))
        for (sig, sev, cat), n in sorted(alerts.items(), key=lambda kv: -kv[1])[:40]:
            lines.append('mediastack_bridge_alerts{host="%s",signature="%s",severity="%s",category="%s"} %d'
                         % (esc(host), esc(sig)[:90], esc(sev), esc(cat)[:50], n))
        print("  suricata_up=%d  stats=%d  alert signatures=%d"
              % (suri_up, len(stats), len(alerts)))
        if "capture.kernel_packets" in stats and stats["capture.kernel_packets"]:
            pct = 100.0 * stats.get("capture.kernel_drops", 0) / stats["capture.kernel_packets"]
            print("  packets=%d drops=%d (%.2f%% cumulative)"
                  % (stats["capture.kernel_packets"], stats.get("capture.kernel_drops", 0), pct))

    lines.append("mediastack_bridge_exporter_last_run_timestamp_seconds %d" % int(started))

    body = "\n".join(lines) + "\n"
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/%s.tmp && mv /t/%s.tmp /t/%s" % (METRIC_FILE, METRIC_FILE, METRIC_FILE)],
        input=body, text=True, capture_output=True)
    if p.returncode != 0:
        print("failed writing metrics: %s" % p.stderr.strip(), file=sys.stderr)
        return 1
    print("  wrote %s in %.1fs" % (METRIC_FILE, time.time() - started))
    # Exit 0 even when the bridge did not answer. Writing
    # mediastack_bridge_reachable=0 IS this collector doing its job, and
    # BridgeUnreachable is what raises the alarm. Returning non-zero made
    # systemd mark the unit failed every two minutes for as long as the
    # bridge was down -- 56 failures an hour, thousands across an outage,
    # which is how a genuine failure later gets lost in the scroll. Only a
    # failure to WRITE metrics is this unit's failure, and that path
    # returns 1 above.
    return 0


if __name__ == "__main__":
    sys.exit(main())
