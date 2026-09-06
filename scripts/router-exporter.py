#!/usr/bin/env python3
"""Export CPU, memory, temperature, throughput and client counts from the
AiMesh routers as Prometheus metrics.

WHY SSH AND NOT SNMP OR SYSLOG

The syslog already shipped to Loki carries events, not numbers: boots, WAN
transitions, DDNS updates, dropbear logins. There is nothing in that stream
to chart, so it cannot answer "how warm is the radio" or "how much is going
through br0". SNMP is not enabled on these units and enabling it means an
Entware package plus an extra listener on the LAN. SSH is already trusted
here, key-based, and every number wanted is a file read away.

MESH NODES ARE NOT AUTOMATIC

An AiMesh node does not forward its logs or metrics anywhere. The two nodes
are separate devices that happen to be centrally configured, which is why
the existing Loki router job only ever showed one host. This discovers them
from the main router's own `cfg_device_list` on each run rather than
hardcoding addresses, so a node that changes DHCP lease is still found.

RUNS AS A USER, NOT ROOT

Unlike the other timers here, this one needs User=numbawon in its unit: the
SSH key is in that user's ~/.ssh and root would not find it. That user is in
the docker group, so writing the metrics still works.

Run by systemd/mediastack-router-exporter.timer.
"""
import os
import re
import subprocess
import sys
import time

TEXTFILE_VOLUME = "node_exporter_textfile"
METRIC_FILE = "router.prom"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
       "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5"]

# Interfaces worth charting. The rest are tunnels and loopbacks that are
# always zero, and every one of them would be a permanent Prometheus series.
IFACE_RE = re.compile(r"^(br\d+|eth\d+|wds\d+\.\d+\.\d+|vlan\d+)$")

# One round trip per device. Each section is prefixed so the parser does not
# depend on ordering or on which sections a given model supports.
PROBE = r"""
echo "MODEL $(nvram get productid 2>/dev/null)"
echo "UPTIME $(cut -d. -f1 /proc/uptime)"
echo "LOAD $(cut -d' ' -f1-3 /proc/loadavg)"
echo "CORES $(grep -c ^processor /proc/cpuinfo)"
awk '/^MemTotal|^MemAvailable|^MemFree/{print "MEM "$1" "$2}' /proc/meminfo
for f in /sys/class/thermal/thermal_zone*/temp; do
  [ -e "$f" ] && echo "THERMAL $(basename $(dirname $f)) $(cat $f)"
done
for i in eth5 eth6 eth7; do
  t=$(wl -i $i phy_tempsense 2>/dev/null | awk '{print $1}')
  [ -n "$t" ] && echo "RADIOTEMP $i $t"
  c=$(wl -i $i assoclist 2>/dev/null | grep -c assoclist)
  [ -n "$c" ] && echo "CLIENTS $i $c"
done
for i in $(ls /sys/class/net 2>/dev/null | grep '^wds'); do
  r=$(wl -i $i rssi 2>/dev/null)
  [ -n "$r" ] && echo "BACKHAUL $i $r"
done
echo "CONNTRACK $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
awk 'NR>2{gsub(":","",$1); print "IFACE "$1" "$2" "$10}' /proc/net/dev
echo "WAN $(nvram get wan0_state_t 2>/dev/null)"
"""


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def probe(host):
    r = subprocess.run(SSH + [host, PROBE], capture_output=True, text=True, timeout=45)
    if r.returncode != 0:
        return None
    return r.stdout


def discover(main):
    """Mesh node addresses from the main router's own AiMesh list.

    cfg_device_list is '>'-separated records of model, ip, mac, flag. Parsing
    it rather than hardcoding means a node that gets a new DHCP lease is still
    found on the next run.
    """
    r = subprocess.run(SSH + [main, "nvram get cfg_device_list"],
                       capture_output=True, text=True, timeout=30)
    ips = []
    if r.returncode == 0:
        for tok in r.stdout.replace("<", ">").split(">"):
            tok = tok.strip()
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", tok) and tok != main:
                ips.append(tok)
    return sorted(set(ips))


def main_fn():
    started = time.time()
    router = os.environ.get("COMMON_LAN_ROUTER")
    if not router:
        print("COMMON_LAN_ROUTER not set", file=sys.stderr)
        return 1

    hosts = [router] + discover(router)
    lines = []
    reachable = 0

    for host in hosts:
        out = probe(host)
        role = "main" if host == router else "node"
        if out is None:
            lines.append('mediastack_router_up{router="%s",role="%s"} 0' % (esc(host), role))
            print("  %-16s UNREACHABLE" % host)
            continue
        reachable += 1

        model = "unknown"
        vals = {}
        for line in out.splitlines():
            p = line.split()
            if not p:
                continue
            k = p[0]
            try:
                if k == "MODEL" and len(p) > 1:
                    model = p[1]
                elif k == "UPTIME":
                    vals["uptime"] = int(p[1])
                elif k == "LOAD":
                    vals["load1"] = float(p[1])
                elif k == "CORES":
                    vals["cores"] = int(p[1])
                elif k == "MEM":
                    vals[p[1].rstrip(":")] = int(p[2]) * 1024
                elif k == "THERMAL":
                    lines.append('mediastack_router_temperature_celsius{router="%s",sensor="%s"} %.1f'
                                 % (esc(host), esc(p[1]), int(p[2]) / 1000.0))
                elif k == "RADIOTEMP":
                    lines.append('mediastack_router_temperature_celsius{router="%s",sensor="radio-%s"} %s'
                                 % (esc(host), esc(p[1]), int(p[2])))
                elif k == "CLIENTS":
                    lines.append('mediastack_router_wifi_clients{router="%s",interface="%s"} %s'
                                 % (esc(host), esc(p[1]), int(p[2])))
                elif k == "BACKHAUL":
                    # wl reports the magnitude; RSSI is negative dBm.
                    lines.append('mediastack_router_backhaul_rssi_dbm{router="%s",interface="%s"} %d'
                                 % (esc(host), esc(p[1]), -abs(int(p[2]))))
                elif k == "CONNTRACK" and len(p) > 2:
                    lines.append('mediastack_router_conntrack_count{router="%s"} %s' % (esc(host), int(p[1])))
                    lines.append('mediastack_router_conntrack_max{router="%s"} %s' % (esc(host), int(p[2])))
                elif k == "IFACE" and IFACE_RE.match(p[1]):
                    lines.append('mediastack_router_interface_rx_bytes_total{router="%s",interface="%s"} %s'
                                 % (esc(host), esc(p[1]), int(p[2])))
                    lines.append('mediastack_router_interface_tx_bytes_total{router="%s",interface="%s"} %s'
                                 % (esc(host), esc(p[1]), int(p[3])))
                elif k == "WAN" and role == "main":
                    # 2 means connected on ASUSWRT. Emitted ONLY for the main
                    # router: a mesh node has no WAN at all, so exporting a 0
                    # for it renders as a red DOWN tile for a link it was never
                    # supposed to have.
                    lines.append('mediastack_router_wan_connected{router="%s",role="%s"} %d'
                                 % (esc(host), role, 1 if p[1] == "2" else 0))
            except (ValueError, IndexError):
                continue

        lab = 'router="%s",role="%s"' % (esc(host), role)
        lines.append('mediastack_router_up{%s} 1' % lab)
        lines.append('mediastack_router_info{%s,model="%s"} 1' % (lab, esc(model)))
        for key, metric in (("uptime", "uptime_seconds"), ("load1", "load1"),
                            ("cores", "cores")):
            if key in vals:
                lines.append('mediastack_router_%s{router="%s"} %s' % (metric, esc(host), vals[key]))
        for key, metric in (("MemTotal", "memory_total_bytes"),
                            ("MemAvailable", "memory_available_bytes"),
                            ("MemFree", "memory_free_bytes")):
            if key in vals:
                lines.append('mediastack_router_%s{router="%s"} %s' % (metric, esc(host), vals[key]))

        print("  %-16s %-10s load=%-5s mem_avail=%sMB temp=%s"
              % (host, model, vals.get("load1", "?"),
                 vals.get("MemAvailable", 0) // 1048576,
                 next((l.split()[-1] for l in lines
                       if "thermal_zone0" in l and esc(host) in l), "?")))

    header = [
        "# HELP mediastack_router_up Whether the router answered over SSH.",
        "# TYPE mediastack_router_up gauge",
        "# HELP mediastack_router_info Model, as a label on a constant 1.",
        "# TYPE mediastack_router_info gauge",
        "# HELP mediastack_router_load1 One-minute load average.",
        "# TYPE mediastack_router_load1 gauge",
        "# HELP mediastack_router_cores CPU cores, for reading load against.",
        "# TYPE mediastack_router_cores gauge",
        "# HELP mediastack_router_memory_total_bytes Total RAM.",
        "# TYPE mediastack_router_memory_total_bytes gauge",
        "# HELP mediastack_router_memory_available_bytes Available RAM.",
        "# TYPE mediastack_router_memory_available_bytes gauge",
        "# HELP mediastack_router_memory_free_bytes Free RAM.",
        "# TYPE mediastack_router_memory_free_bytes gauge",
        "# HELP mediastack_router_temperature_celsius SoC and per-radio temperatures.",
        "# TYPE mediastack_router_temperature_celsius gauge",
        "# HELP mediastack_router_wifi_clients Stations associated per radio.",
        "# TYPE mediastack_router_wifi_clients gauge",
        "# HELP mediastack_router_backhaul_rssi_dbm Mesh backhaul signal, negative dBm.",
        "# TYPE mediastack_router_backhaul_rssi_dbm gauge",
        "# HELP mediastack_router_conntrack_count Tracked connections.",
        "# TYPE mediastack_router_conntrack_count gauge",
        "# HELP mediastack_router_conntrack_max Connection tracking table size.",
        "# TYPE mediastack_router_conntrack_max gauge",
        "# HELP mediastack_router_interface_rx_bytes_total Interface bytes received.",
        "# TYPE mediastack_router_interface_rx_bytes_total counter",
        "# HELP mediastack_router_interface_tx_bytes_total Interface bytes transmitted.",
        "# TYPE mediastack_router_interface_tx_bytes_total counter",
        "# HELP mediastack_router_uptime_seconds Seconds since boot.",
        "# TYPE mediastack_router_uptime_seconds gauge",
        "# HELP mediastack_router_wan_connected Whether the main router's WAN is up.",
        "# TYPE mediastack_router_wan_connected gauge",
        "# HELP mediastack_router_exporter_reachable Routers that answered this run.",
        "# TYPE mediastack_router_exporter_reachable gauge",
        "# HELP mediastack_router_exporter_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_router_exporter_last_run_timestamp_seconds gauge",
    ]
    lines.append("mediastack_router_exporter_reachable %d" % reachable)
    lines.append("mediastack_router_exporter_expected %d" % len(hosts))
    lines.append("mediastack_router_exporter_last_run_timestamp_seconds %d" % int(started))

    body = "\n".join(header + lines) + "\n"
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/%s.tmp && mv /t/%s.tmp /t/%s" % (METRIC_FILE, METRIC_FILE, METRIC_FILE)],
        input=body, text=True, capture_output=True)
    if p.returncode != 0:
        print("failed writing metrics: %s" % p.stderr.strip(), file=sys.stderr)
        return 1

    print("%d/%d router(s) reachable, %.1fs" % (reachable, len(hosts), time.time() - started))
    return 0 if reachable else 1


if __name__ == "__main__":
    sys.exit(main_fn())
