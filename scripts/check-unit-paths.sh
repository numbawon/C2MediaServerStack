#!/usr/bin/env bash
# Catch the two ways systemd units go wrong here, neither of which announces
# itself.
#
# 1. A unit in systemd/ has a REAL path baked in instead of the placeholder.
#    These files are tracked, so a real path is both a leak of the install
#    location and a trap for anyone else installing from this repo. It has
#    happened by half-edit: WorkingDirectory pointing at the real path while
#    ExecStart still said youruser, which installs cleanly and then fails.
#
# 2. An INSTALLED unit still points at /home/youruser. It was copied without
#    substituting, so it fails on first fire, and a timer that has never
#    fired looks exactly like one with nothing to report.
#
# Read-only. Exits non-zero if either is true, so it works as a pre-commit
# check or a manual sanity pass.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PLACEHOLDER="/home/youruser/C2MediaServerStack"
rc=0

echo "==> repo copies should use the placeholder"
for f in systemd/*.service systemd/*.timer systemd/*.conf; do
  [ -e "$f" ] || continue
  # directives only; the install instructions in the comments legitimately
  # say "replace youruser", and a real path there is harmless
  bad=$(grep -nE '^(WorkingDirectory|ExecStart|ExecStartPre|ExecStop|EnvironmentFile)=' "$f" \
        | grep -v "$PLACEHOLDER" | grep -E '/home/[^y]' || true)
  if [ -n "$bad" ]; then
    echo "    REAL PATH in $f:"
    echo "$bad" | sed 's/^/      /'
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "    all repo units use the placeholder"

echo "==> installed copies should NOT"
found=0
for f in /etc/systemd/system/mediastack-*.service /etc/systemd/system/ttyd.service \
         /etc/systemd/system/cloudflared-emergency.service; do
  [ -e "$f" ] || continue
  found=$((found+1))
  # User=youruser too, not just paths. router-exporter runs as a user rather
  # than root because the SSH key lives in a home directory, and a leftover
  # User=youruser fails at start with "Failed to determine user credentials"
  # rather than anything mentioning the placeholder.
  bad=$(grep -nE '^(WorkingDirectory|ExecStart|ExecStartPre|ExecStop|EnvironmentFile|User)=' "$f" \
        | grep -E "$PLACEHOLDER|^[0-9]+:User=youruser" || true)
  if [ -n "$bad" ]; then
    echo "    PLACEHOLDER LEFT IN $f:"
    echo "$bad" | sed 's/^/      /'
    echo "      this unit will fail on first fire"
    rc=1
  fi
done
if [ "$found" -eq 0 ]; then
  echo "    no units installed yet"
elif [ "$rc" -eq 0 ]; then
  echo "    all $found installed units point at a real path"
fi

echo "==> every installed unit's paths should exist"
for f in /etc/systemd/system/mediastack-*.service; do
  [ -e "$f" ] || continue
  while IFS= read -r line; do
    val="${line#*=}"
    for tok in $val; do
      case "$tok" in
        /*) [ -e "$tok" ] || { echo "    MISSING: $(basename "$f") -> $tok"; rc=1; } ;;
      esac
    done
  done < <(grep -E '^(WorkingDirectory|ExecStart|EnvironmentFile)=' "$f")
done
[ "$rc" -eq 0 ] && echo "    all referenced paths resolve"

exit "$rc"
