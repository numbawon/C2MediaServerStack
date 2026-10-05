#!/usr/bin/env bash
# The mirror's pulse. The node's two NVMes are one btrfs RAID1 filesystem:
# every block lives on both disks, which only protects you if you KNOW when
# a copy goes bad. btrfs counts errors per disk as they happen and a scrub
# re-reads and compares every block; this turns both into metrics so a
# weakening mirror is an alert, not a surprise at the worst moment.
#
#   mediastack-node-btrfs.sh stats   hourly: per-disk error counters, and
#                                    whether every profile is still RAID1
#   mediastack-node-btrfs.sh scrub   monthly: full scrub, then its totals
#
# Runs as root (btrfs needs it) from mediastack-node-btrfs-*.timer. Metrics
# go to the node-exporter textfile directory, one file per mode so the
# hourly run never overwrites the monthly result.
set -euo pipefail

MODE="${1:?usage: $0 stats|scrub}"
FS="${BTRFS_FS:-/}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/docker/volumes/node_exporter_textfile/_data}"

write_prom() {  # $1 = file name, body on stdin
  [ -d "$TEXTFILE_DIR" ] || return 0
  local tmp="$TEXTFILE_DIR/.$1.$$"
  cat >"$tmp" && mv "$tmp" "$TEXTFILE_DIR/$1"
}

stats() {
  local out
  out=$(btrfs device stats "$FS")
  {
    echo '# HELP mediastack_node_btrfs_device_errors_total Per-disk btrfs error counter (write/read/flush io, corruption, generation).'
    echo '# TYPE mediastack_node_btrfs_device_errors_total gauge'
    # "[/dev/nvme0n1p1].write_io_errs   0"  ->  device, type, count
    awk '{ if (match($1, /^\[(.*)\]\.(.*)$/, m)) printf "mediastack_node_btrfs_device_errors_total{device=\"%s\",type=\"%s\"} %s\n", m[1], m[2], $2 }' <<<"$out"

    # Every allocated profile must be RAID1. A profile that fell back to
    # single/dup (a device dropped, a balance interrupted) leaves data on
    # one disk with no copy, and nothing else would say so.
    local bad
    bad=$(btrfs filesystem df "$FS" | awk -F'[ ,:]+' '/^(Data|Metadata|System)/ && $2 != "RAID1" { n++ } END { print n+0 }')
    echo '# HELP mediastack_node_btrfs_raid1 1 if data, metadata and system are all RAID1.'
    echo '# TYPE mediastack_node_btrfs_raid1 gauge'
    echo "mediastack_node_btrfs_raid1 $([ "$bad" -eq 0 ] && echo 1 || echo 0)"
    echo '# TYPE mediastack_node_btrfs_stats_last_run_timestamp_seconds gauge'
    echo "mediastack_node_btrfs_stats_last_run_timestamp_seconds $(date +%s)"
  } | write_prom node_btrfs_stats.prom
}

scrub() {
  local ok=1
  # -B: stay in the foreground until the scrub ends. Exit status is
  # non-zero when it found uncorrectable errors, which is data, not a crash.
  btrfs scrub start -B "$FS" >/dev/null || ok=0
  local raw
  raw=$(btrfs scrub status -R "$FS")
  local errors corrected
  # Errors the mirror could NOT fix, plus anything structurally wrong.
  errors=$(awk '/^[ \t]*(read_errors|csum_errors|verify_errors|super_errors|uncorrectable_errors|unverified_errors):/ { s += $2 } END { print s+0 }' <<<"$raw")
  # Errors it found AND healed from the other copy: the mirror doing its job,
  # but the disk that needed healing is worth watching.
  corrected=$(awk '/^[ \t]*corrected_errors:/ { s += $2 } END { print s+0 }' <<<"$raw")
  [ "$errors" -eq 0 ] || ok=0
  {
    echo '# HELP mediastack_node_btrfs_scrub_success 1 if the last scrub finished with no unrecoverable errors.'
    echo '# TYPE mediastack_node_btrfs_scrub_success gauge'
    echo "mediastack_node_btrfs_scrub_success $ok"
    echo '# TYPE mediastack_node_btrfs_scrub_errors gauge'
    echo "mediastack_node_btrfs_scrub_errors $errors"
    echo '# TYPE mediastack_node_btrfs_scrub_corrected_errors gauge'
    echo "mediastack_node_btrfs_scrub_corrected_errors $corrected"
    echo '# TYPE mediastack_node_btrfs_scrub_last_run_timestamp_seconds gauge'
    echo "mediastack_node_btrfs_scrub_last_run_timestamp_seconds $(date +%s)"
  } | write_prom node_btrfs_scrub.prom
  echo "scrub done: errors=$errors corrected=$corrected"
  [ "$ok" -eq 1 ]
}

case "$MODE" in
  stats) stats ;;
  scrub) scrub ;;
  *) echo "usage: $0 stats|scrub" >&2; exit 2 ;;
esac
