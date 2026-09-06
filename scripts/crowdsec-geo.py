#!/usr/bin/env python3
"""Export CrowdSec alert sources, with coordinates, as Prometheus metrics.

CrowdSec already does the hard part. It ships GeoLite2-City and GeoLite2-ASN
databases and runs the crowdsecurity/geoip-enrich parser over every log line,
so each alert already carries the source IP's country, latitude, longitude
and AS name. Nothing here does any lookup; it reads what CrowdSec decided.

WHY LAT/LON ARE LABELS

Grafana's Geomap wants numeric latitude and longitude fields. Prometheus has
no way to attach numbers to a series except as label values, so they go in
as labels and the dashboard uses a labelsToFields transformation to turn
them back into columns. It reads oddly and it is the normal approach.

CARDINALITY IS THE REAL CONSTRAINT

One series per attacking IP, and attacking IPs are unbounded: a scanner
sweep can add hundreds in an afternoon, each one a permanent new series in
Prometheus. So this caps at MAX_SOURCES most-recent IPs and exports a
separate per-country metric that is bounded by roughly 250 no matter what
happens. If you want history beyond the cap, the country metric is the one
to trust.

Run by systemd/mediastack-crowdsec-geo.timer.
"""
import json
import os
import subprocess
import sys
import time

TEXTFILE_VOLUME = "node_exporter_textfile"
METRIC_FILE = "crowdsec_geo.prom"
CS_FILTER = "mediastack_crowdsec"

# How many individual sources to plot. Each is a Prometheus series that lives
# until the next restart, so this is a deliberate ceiling rather than a
# performance guess.
MAX_SOURCES = int(os.environ.get("CROWDSEC_GEO_MAX_SOURCES", "200"))
# How far back to read. CrowdSec prunes its own alert history separately.
ALERT_LIMIT = int(os.environ.get("CROWDSEC_GEO_ALERT_LIMIT", "1000"))


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def main():
    started = time.time()
    ok = 1
    lines = []

    r = sh(["docker", "ps", "--filter", "name=" + CS_FILTER, "--format", "{{.Names}}"])
    names = [n for n in r.stdout.split() if n]
    if not names:
        print("crowdsec container not found", file=sys.stderr)
        alerts = []
        ok = 0
    else:
        r = sh(["docker", "exec", names[0], "cscli", "alerts", "list",
                "--limit", str(ALERT_LIMIT), "-o", "json"])
        if r.returncode != 0:
            print("cscli failed: " + r.stderr.strip()[:200], file=sys.stderr)
            alerts = []
            ok = 0
        else:
            try:
                alerts = json.loads(r.stdout) or []
            except ValueError:
                # cscli prints "null" rather than [] when there is nothing
                alerts = []

    by_ip = {}
    by_country = {}
    for a in alerts:
        src = a.get("source") or {}
        ip = src.get("ip")
        lat, lon = src.get("latitude"), src.get("longitude")
        country = src.get("cn") or "??"
        as_name = src.get("as_name") or "unknown"
        created = a.get("created_at") or ""

        by_country[country] = by_country.get(country, 0) + 1

        # No coordinates means MaxMind had no answer for it, which is normal
        # for private ranges and some cloud allocations. Counted by country,
        # not plotted, rather than dropped into the ocean at 0,0.
        if ip is None or lat is None or lon is None:
            continue
        e = by_ip.setdefault(ip, {"n": 0, "lat": lat, "lon": lon,
                                  "country": country, "as_name": as_name,
                                  "last": created})
        e["n"] += 1
        if created > e["last"]:
            e["last"] = created

    ranked = sorted(by_ip.items(), key=lambda kv: kv[1]["last"], reverse=True)
    plotted = ranked[:MAX_SOURCES]

    header = [
        "# HELP mediastack_crowdsec_alerts_by_source Alerts recorded per source IP, with coordinates for mapping.",
        "# TYPE mediastack_crowdsec_alerts_by_source gauge",
        "# HELP mediastack_crowdsec_alerts_by_country Alerts per country. Bounded cardinality, unlike the per-source metric.",
        "# TYPE mediastack_crowdsec_alerts_by_country gauge",
        "# HELP mediastack_crowdsec_geo_sources_total Distinct source IPs seen in the window.",
        "# TYPE mediastack_crowdsec_geo_sources_total gauge",
        "# HELP mediastack_crowdsec_geo_sources_plotted Sources actually exported, capped by MAX_SOURCES.",
        "# TYPE mediastack_crowdsec_geo_sources_plotted gauge",
        "# HELP mediastack_crowdsec_geo_success Whether the last run read CrowdSec.",
        "# TYPE mediastack_crowdsec_geo_success gauge",
        "# HELP mediastack_crowdsec_geo_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_crowdsec_geo_last_run_timestamp_seconds gauge",
    ]

    for ip, e in plotted:
        lab = ('ip="%s",country="%s",as_name="%s",latitude="%s",longitude="%s"'
               % (esc(ip), esc(e["country"]), esc(e["as_name"]), e["lat"], e["lon"]))
        lines.append("mediastack_crowdsec_alerts_by_source{%s} %d" % (lab, e["n"]))

    for country, n in sorted(by_country.items()):
        lines.append('mediastack_crowdsec_alerts_by_country{country="%s"} %d' % (esc(country), n))

    lines.append("mediastack_crowdsec_geo_sources_total %d" % len(by_ip))
    lines.append("mediastack_crowdsec_geo_sources_plotted %d" % len(plotted))
    lines.append("mediastack_crowdsec_geo_success %d" % ok)
    lines.append("mediastack_crowdsec_geo_last_run_timestamp_seconds %d" % int(started))

    body = "\n".join(header + lines) + "\n"
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/%s.tmp && mv /t/%s.tmp /t/%s" % (METRIC_FILE, METRIC_FILE, METRIC_FILE)],
        input=body, text=True, capture_output=True)
    if p.returncode != 0:
        print("failed writing metrics: %s" % p.stderr.strip(), file=sys.stderr)
        return 1

    print("  %d alert(s), %d distinct source(s), %d plotted, %d country(ies)"
          % (len(alerts), len(by_ip), len(plotted), len(by_country)))
    for country, n in sorted(by_country.items(), key=lambda kv: -kv[1])[:5]:
        print("    %-4s %d" % (country, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
