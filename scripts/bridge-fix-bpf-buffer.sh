#!/usr/bin/env bash
# Raise Suricata's pcap capture buffer on the filtering bridge.
#
# Why: the bridge was dropping 3-9% of packets while its CPU sat at 0.2%,
# load at 0.11 across 4 cores, and memcap_pressure at 5 of 100, all at
# only ~1000 pkt/s. None of that is saturation. The cause is FreeBSD's
# default net.bpf.bufsize of 4096 bytes with `buffer-size` left commented
# out in the pcap: section of suricata.yaml, which is two or three frames
# of headroom -- any scheduling delay drops whatever arrives in between.
#
# Setting buffer-size in suricata.yaml is enough on its own: it becomes a
# pcap_set_buffer_size call, bounded by net.bpf.maxbufsize, which is
# already 16777216 here. No sysctl change and no reboot.
#
# NOTE: that Suricata is not OPNsense-managed (no <ids> block in
# /conf/config.xml; it runs from /usr/local/etc/rc.d/suricata), so this
# edit persists. But the IDS plugin's templates ARE installed, and
# enabling that plugin later regenerates suricata.yaml and silently
# discards this. Re-run afterwards if that ever happens.
#
# Restarting Suricata zeroes every counter, which resets the observation
# window. That is intended: there is no value in measuring the stability
# of a configuration you already know is wrong.
#
#   ./scripts/bridge-fix-bpf-buffer.sh            # apply
#   ./scripts/bridge-fix-bpf-buffer.sh --check    # report, change nothing
set -euo pipefail

HOST="${COMMON_BRIDGE_HOST:-}"
SIZE="${BRIDGE_PCAP_BUFFER:-16777216}"
YAML=/usr/local/etc/suricata/suricata.yaml
MODE="${1:-apply}"

if [ -z "$HOST" ]; then
  echo "COMMON_BRIDGE_HOST not set (source .env first)" >&2
  exit 1
fi

ssh_bridge() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$HOST" sh
}

if ! ping -c 2 -W 3 "$HOST" >/dev/null 2>&1; then
  echo "bridge $HOST is not reachable; nothing done" >&2
  exit 1
fi

# The edit is scoped to the `pcap:` block alone. suricata.yaml contains
# several other buffer-size keys -- nflog has one, and pcap-file follows
# immediately after pcap -- so a file-wide substitution would land in the
# wrong section and appear to work.
read -r -d '' REMOTE <<REMOTE_EOF || true
set -e
MODE="$MODE"
SIZE="$SIZE"
YAML="$YAML"

echo "== before =="
sudo awk '/^pcap:/{f=1} f&&/buffer-size/{print "  " \$0} /^pcap-file:/{f=0}' "\$YAML" || true
echo "  net.bpf.bufsize    = \$(sysctl -n net.bpf.bufsize)"
echo "  net.bpf.maxbufsize = \$(sysctl -n net.bpf.maxbufsize)"

if [ "\$MODE" = "--check" ]; then
  echo "== check only, no changes =="
  exit 0
fi

if [ "\$SIZE" -gt "\$(sysctl -n net.bpf.maxbufsize)" ]; then
  echo "requested buffer \$SIZE exceeds net.bpf.maxbufsize; refusing" >&2
  exit 1
fi

sudo cp -p "\$YAML" "\$YAML.bak-\$(date +%Y%m%d%H%M%S)"

sudo python3 - "\$YAML" "\$SIZE" <<'PY'
import re, sys
path, size = sys.argv[1], int(sys.argv[2])
lines = open(path).read().splitlines(True)
start = next(i for i, l in enumerate(lines) if l.startswith("pcap:"))
end = next((i for i in range(start + 1, len(lines))
            if lines[i] and not lines[i][0].isspace() and not lines[i].startswith("#")),
           len(lines))
for i in range(start, end):
    if re.match(r"\s*#?\s*buffer-size\s*:", lines[i]):
        indent = re.match(r"(\s*)", lines[i]).group(1)
        lines[i] = "%sbuffer-size: %d\n" % (indent, size)
        break
else:
    lines.insert(start + 2, "      buffer-size: %d\n" % size)
open(path, "w").write("".join(lines))
print("  pcap buffer-size set to %d" % size)
PY

echo "== restarting suricata (counters reset) =="
sudo service suricata restart >/dev/null 2>&1 || sudo /usr/local/etc/rc.d/suricata restart >/dev/null 2>&1
sleep 5
pid=\$(sudo pgrep -f 'suricata .*--pcap' | head -1 || true)
if [ -z "\$pid" ]; then
  echo "SURICATA DID NOT COME BACK -- restore the .bak file" >&2
  exit 1
fi
echo "  suricata running, pid \$pid"

echo "== after =="
sudo awk '/^pcap:/{f=1} f&&/buffer-size/{print "  " \$0} /^pcap-file:/{f=0}' "\$YAML"
REMOTE_EOF

printf '%s\n' "$REMOTE" | ssh_bridge
