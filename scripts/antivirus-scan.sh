#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
source .env
set +a

case "${1:-}" in
  full)
    state_dir="${COMMON_CONFIG}/antivirus"
    install -d -m 0750 "$state_dir"
    printf 'requested_at=%(%s)T\n' -1 > "$state_dir/rescan.request"
    docker service update --quiet --force mediastack_antivirus-exporter >/dev/null
    echo "Full antivirus rescan queued; progress: scripts/antivirus-scan.sh status"
    ;;
  status)
    container_id="$(
      docker ps \
        --filter label=com.docker.swarm.service.name=mediastack_antivirus-exporter \
        --quiet |
        head -1
    )"
    if [ -z "$container_id" ]; then
      echo "antivirus-exporter is not running" >&2
      exit 1
    fi
    docker exec "$container_id" python -c \
      "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9102/metrics').read().decode(), end='')"
    ;;
  *)
    echo "Usage: $0 {full|status}" >&2
    exit 1
    ;;
esac
