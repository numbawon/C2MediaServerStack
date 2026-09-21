#!/usr/bin/env bash
# Static checks that need no running stack and no real secrets, so they run in
# CI on every push and locally before a deploy:
#   - .env.example satisfies validate-env.py
#   - every stateful swarm service is pinned (swarm-preflight.sh)
#   - docker-stack.yml and each docker-compose.*.yml render with .env.example
#   - shellcheck on scripts/*.sh (warnings and errors; the three exclusions are
#     noise in this repo: sourcing .env, and `cd` under `set -e`)
#
#   ./scripts/ci-validate.sh
#   CI=true ./scripts/ci-validate.sh   # also creates empty stubs for the
#                                      # git-ignored files compose expects
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
step() { printf '\n== %s\n' "$1"; }
run() { "$@" || { echo "FAIL: $*" >&2; fail=1; }; }

# Real, git-ignored files that compose files reference. A clean CI checkout
# lacks them, so give it empty ones; never do this on a live machine.
if [ "${CI:-}" = "true" ]; then
  mkdir -p secrets
  while IFS= read -r f; do
    [ -e "$f" ] || { mkdir -p "$(dirname "$f")"; : > "$f"; }
  done < <(grep -rhoE '(\./)?secrets/[A-Za-z0-9_./-]+\.env' docker-compose.*.yml docker-stack.yml | sed 's|^\./||' | sort -u)
fi

set -a
# shellcheck disable=SC1091
source .env.example
set +a

step "validate-env.py against .env.example"
run python3 scripts/validate-env.py

step "swarm-preflight"
run ./scripts/swarm-preflight.sh

step "docker stack config"
run docker stack config -c docker-stack.yml >/dev/null

step "docker compose config"
for f in docker-compose.*.yml; do
  [ -e "$f" ] || continue
  if docker compose -f "$f" config -q >/dev/null 2>&1; then
    echo "ok  $f"
  else
    echo "FAIL $f" >&2
    docker compose -f "$f" config -q 2>&1 | head -5 >&2 || true
    fail=1
  fi
done

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  run shellcheck -S warning -e SC1090,SC1091,SC2164 -x scripts/*.sh
else
  echo "shellcheck not installed, skipping"
fi

echo
[ "$fail" -eq 0 ] && echo "ci-validate: ok" || echo "ci-validate: FAILED" >&2
exit "$fail"
