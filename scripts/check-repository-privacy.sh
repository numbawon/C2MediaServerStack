#!/usr/bin/env bash
# Scan publishable repository content for deployment-specific values.
# git grep reads tracked worktree files only, so ignored runtime data is never
# inspected or accidentally printed.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

rc=0
username="numba""won"
approved_skill=".claude/skills/is-it-new/SKILL.md"

report_literal() {
  local label="$1"
  local literal="$2"
  local matches

  matches="$(git grep -n -I -F -e "$literal" -- 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    echo "PRIVATE VALUE: $label"
    printf '%s\n' "$matches" | sed 's/^/  /'
    rc=1
  fi
}

report_address() {
  local label="$1"
  local address="$2"
  local pattern="${address//./\\.}"
  local matches

  matches="$(git grep -n -I -E -e "(^|[^0-9.])${pattern}([^0-9.]|$)" -- 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    echo "PRIVATE VALUE: $label"
    printf '%s\n' "$matches" | sed 's/^/  /'
    rc=1
  fi
}

report_literal "deployment domain" "${username}.xyz"
report_literal "LAN subnet" "192.168.50.""0/24"
report_address "router address" "192.168.50.""1"
report_address "LAN host address" "192.168.50.""10"
report_address "observed public address" "187.14.87.""182"
report_address "observed public address" "187.13.212.""16"
report_literal "deployment hostname" "C2""Storage"
report_literal "deployment hostname" "C2-""Pihole"
report_literal "personal home path" "/home/${username}"

ssh_ca_path="cloudflared/access-ssh-ca.""pub"
if git ls-files --error-unmatch -- "$ssh_ca_path" >/dev/null 2>&1; then
  echo "PRIVATE FILE: deployment-specific SSH CA must not be tracked"
  echo "  $ssh_ca_path"
  rc=1
fi

# Username references are private unless they identify repository/image
# ownership. The approved repository skill may also name its author/user.
while IFS=: read -r file line text; do
  [ "$file" = "$approved_skill" ] && continue
  remainder="${text//github.com\/${username}/}"
  remainder="${remainder//ghcr.io\/${username}/}"
  remainder="${remainder//${username}\/organizarr/}"
  remainder="${remainder//${username}\/C2MediaServerStack/}"
  remainder="${remainder//${username}.xyz/}"
  remainder="${remainder//\/home\/${username}/}"
  if [[ "$remainder" == *"$username"* ]]; then
    echo "PRIVATE VALUE: personal username"
    printf '  %s:%s:%s\n' "$file" "$line" "$text"
    rc=1
  fi
done < <(git grep -n -I -F -e "$username" -- 2>/dev/null || true)

if [ "$rc" -eq 0 ]; then
  echo "Repository privacy check passed (tracked files only)."
else
  echo "Repository privacy check failed."
fi

exit "$rc"
