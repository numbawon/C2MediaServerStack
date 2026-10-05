#!/usr/bin/env bash
# Is last night's worker-node backup an actual backup, or just a file?
#
# Each worker pushes a tar of its local state to .appdata/node-backups/ every
# night (nuc-nodes/common/mediastack-node-backup.sh), and the manager's local
# and off-site jobs carry those tars onward. The node-side job reports
# "succeeded" when ITS end finished, which says nothing about what landed
# here: a stuck upload leaves yesterday's file looking current, a dropped
# connection can leave a tar that will not open, and a node whose state
# directory went missing can send a perfectly valid, nearly empty archive.
#
# So this goes and looks, per tar:
#   - fresh      modified within MAX_AGE_HOURS (default 36: one missed night
#                plus slack, not two)
#   - readable   `tar -tf` walks the whole archive without error, and
#                reports how many entries it holds
#   - not hollow at least MIN_RATIO (default 0.5) of the last size it passed
#                at. A backup that quietly shrank to nothing is the failure
#                no freshness check can see. The remembered size only moves
#                when a check passes, so a bad night cannot become the new
#                normal.
#
# Results become Prometheus metrics, so a node backup that stops being real
# is an alert (NodeBackupInvalid / NodeBackupFileStale) instead of a
# discovery during the restore you needed it for.
#
# A node that has NEVER delivered a tar has no file to find; that gap is
# covered node-side by NodeBackupStale.
#
# Run by systemd/mediastack-check-node-backups.timer.
set -uo pipefail   # NOT -e: a failed check must still write its metrics

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DIR="${NODE_BACKUP_DIR:-.appdata/node-backups}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
MIN_RATIO="${MIN_RATIO:-0.5}"
TEXTFILE_VOLUME="node_exporter_textfile"
METRIC_FILE="node_backup_check.prom"

shopt -s nullglob
tars=("$DIR"/*.tar)
now=$(date +%s)
overall=0
body=""

for tar_path in "${tars[@]}"; do
  node="$(basename "$tar_path" .tar)"
  state="$DIR/.last-size.$node"
  ok=1; why=""

  bytes=$(stat -c %s "$tar_path")
  age=$(( now - $(stat -c %Y "$tar_path") ))
  [ "$age" -le $(( MAX_AGE_HOURS * 3600 )) ] || { ok=0; why="$why stale(${age}s)"; }

  entries=$(tar -tf "$tar_path" 2>/dev/null | wc -l)
  if ! tar -tf "$tar_path" >/dev/null 2>&1; then ok=0; entries=0; why="$why unreadable"; fi
  [ "$entries" -gt 0 ] || { ok=0; why="$why empty"; }

  prev=$(cat "$state" 2>/dev/null || echo 0)
  if [ "$prev" -gt 0 ] && awk -v b="$bytes" -v p="$prev" -v r="$MIN_RATIO" 'BEGIN{exit !(b < p*r)}'; then
    ok=0; why="$why shrank(${prev}->${bytes})"
  fi

  if [ "$ok" -eq 1 ]; then
    echo "$bytes" > "$state"
    echo "ok     $node  ${bytes}B  ${entries} entries  age ${age}s"
  else
    overall=1
    echo "FAILED $node ->$why"
  fi
  body+="mediastack_node_backup_check_ok{node=\"$node\"} $ok
mediastack_node_backup_file_age_seconds{node=\"$node\"} $age
mediastack_node_backup_file_bytes{node=\"$node\"} $bytes
mediastack_node_backup_file_entries{node=\"$node\"} $entries
"
done

[ "${#tars[@]}" -gt 0 ] || { echo "FAILED no node tars found in $DIR"; overall=1; }

metrics="# HELP mediastack_node_backup_check_ok 1 if the node's tar on the manager is fresh, readable and not hollow.
# TYPE mediastack_node_backup_check_ok gauge
# TYPE mediastack_node_backup_file_age_seconds gauge
# TYPE mediastack_node_backup_file_bytes gauge
# TYPE mediastack_node_backup_file_entries gauge
${body}# TYPE mediastack_node_backup_check_tars gauge
mediastack_node_backup_check_tars ${#tars[@]}
# TYPE mediastack_node_backup_check_last_run_timestamp_seconds gauge
mediastack_node_backup_check_last_run_timestamp_seconds $now
"

# Atomic, like the other backup scripts: node-exporter parses any *.prom in
# the directory, and a half-written file yields garbage metrics.
if [ -n "${TEXTFILE_DIR:-}" ]; then
  printf '%s' "$metrics" > "$TEXTFILE_DIR/$METRIC_FILE.tmp" && mv "$TEXTFILE_DIR/$METRIC_FILE.tmp" "$TEXTFILE_DIR/$METRIC_FILE"
else
  printf '%s' "$metrics" | docker run --rm -i -v "${TEXTFILE_VOLUME}:/t" alpine:latest \
    sh -c "cat > /t/${METRIC_FILE}.tmp && mv /t/${METRIC_FILE}.tmp /t/${METRIC_FILE}" 2>/dev/null || true
fi
exit "$overall"
