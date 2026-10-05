#!/usr/bin/env bash
# The manager end of the node backup. Installed as the forced command for
# each worker's dedicated backup key (see ansible/playbooks/node-maintenance.yml):
#
#   restrict,command="/path/to/scripts/node-backup-receive.sh <nodename>" ssh-ed25519 ...
#
# A worker that is compromised, or just misconfigured, can therefore do exactly
# one thing on the manager: replace its OWN <nodename>.tar in one fixed
# directory. No shell, no other paths, no other nodes' files.
#
# The node name is baked into the authorized_keys line by the playbook, never
# taken from the client, so a node cannot write someone else's file.
set -euo pipefail
node="${1:?node name required}"
[[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad node name" >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
dir=".appdata/node-backups"
mkdir -p "$dir"

# Write to a temp name and rename, so a dropped connection never replaces
# the last good copy with a truncated archive.
tmp="$dir/$node.tar.partial"
cat > "$tmp"
# An empty or tiny archive means the node-side tar died; keep yesterday's.
size=$(stat -c %s "$tmp")
if [ "$size" -lt 1024 ]; then rm -f "$tmp"; echo "refusing a ${size}-byte archive" >&2; exit 1; fi
mv "$tmp" "$dir/$node.tar"
echo "$size"
