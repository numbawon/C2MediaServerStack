#!/usr/bin/env bash
# The three real, git-ignored config files (cloudflared/config.yml,
# cloudflared/emergency-config.yml, homer/config.yml) each have a tracked
# .example twin with placeholders instead of real values. Since git no
# longer diffs the real files, nothing forces the .example to stay in
# sync when a real file changes for a genuine reason (a new Homer tile, a
# new ingress hostname) -- this script is that missing diff.
#
# It normalizes each real file (swap real domain/user/home-path back to
# the placeholders) and diffs the result against its .example. A clean
# diff means the .example is just the real file with secrets swapped out,
# same as it should be. Anything else prints as a real structural
# difference worth looking at -- most often "I added something to the
# real file and forgot the .example."
#
# Run manually after editing any of the three, or before a commit that
# touches homer/ or cloudflared/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a
source .env
set +a

REAL_USER="${USER:-$(id -un)}"

# e.g. 10.9.8.0/24 -> prefix 10.9.8, router 10.9.8.1
LAN_PREFIX="${COMMON_LAN_SUBNET%%/*}"; LAN_PREFIX="${LAN_PREFIX%.*}"
LAN_ROUTER="${LAN_PREFIX}.1"

normalize() {
  # Order matters: the domain check has to run before the bare-username
  # one, same reasoning as the git-filter-repo rules used to scrub
  # history -- a bare username replace running first would also eat the
  # username-shaped part of the domain if they ever happen to collide.
  # LAN addresses before the domain: they are the other class of value
  # these files leak. The router IP is derived from COMMON_LAN_SUBNET
  # rather than hardcoded, so this keeps working if the LAN is
  # renumbered. Longest-first ordering matters -- substituting the /24
  # prefix before the specific hosts would corrupt them.
  sed \
    -e "s#${COMMON_LAN_IP}#192.168.1.10#g" \
    -e "s#${LAN_ROUTER}#192.168.1.1#g" \
    -e "s#${LAN_PREFIX}\.#192.168.1.#g" \
    -e "s#${COMMON_DOMAIN}#example.com#g" \
    -e "s#/home/${REAL_USER}#/home/youruser#g" \
    -e "s#User=${REAL_USER}#User=youruser#g"
}

# Lines matching this (grep -E, applied to both sides before diffing) are
# always expected to differ -- real per-secret values with no placeholder
# pattern to normalize against (the tunnel ID has no home in .env) -- so
# masking them out here is correct, not a loophole.
mask() {
  sed -E 's#^(tunnel|credentials-file):.*#\1: <MASKED>#'
}

check_pair() {
  local real="$1" example="$2"
  if [ ! -f "$real" ]; then
    echo "skip: $real doesn't exist (not set up yet?)"
    return
  fi
  local diff_out
  diff_out="$(diff -u <(mask < "$example") <(normalize < "$real" | mask) || true)"
  if [ -z "$diff_out" ]; then
    echo "OK:   $example matches $real (placeholders aside)"
  else
    echo "DRIFT: $example is out of sync with $real"
    echo "$diff_out"
    echo
  fi
}

check_pair cloudflared/config.yml           cloudflared/config.yml.example
check_pair cloudflared/emergency-config.yml cloudflared/emergency-config.yml.example
check_pair homer/config.yml                 homer/config.yml.example
