#!/usr/bin/env bash
# Checks the Swarm stack is safe to deploy on a multi-node cluster.
#
# Bind mounts and named volumes are both local to one node. A service with
# either and no placement constraint can be scheduled on a node that has no
# copy of its data: a bind mount fails loudly, a named volume silently
# starts empty. So every service that mounts anything must be pinned to the
# node labelled role=core, and that label must exist or nothing schedules.
#
#   ./scripts/swarm-preflight.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

unpinned=$(python3 - <<'PY'
import yaml
d = yaml.safe_load(open("docker-stack.yml"))
for name, svc in d["services"].items():
    if not svc.get("volumes"):
        continue
    cons = ((svc.get("deploy") or {}).get("placement") or {}).get("constraints") or []
    if "node.labels.role == core" not in cons:
        print(name)
PY
)
if [ -n "$unpinned" ]; then
  echo "FAIL: services with volumes but no 'node.labels.role == core' constraint:" >&2
  echo "$unpinned" | sed 's/^/  /' >&2
  fail=1
fi

if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q '^active$'; then
  core=$(docker node ls -q --filter node.label=role=core 2>/dev/null | wc -l)
  if [ "$core" -lt 1 ]; then
    echo "FAIL: no node is labelled role=core, pinned services would stay Pending." >&2
    echo "  docker node update --label-add role=core <node>" >&2
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "swarm-preflight: ok"
exit "$fail"
