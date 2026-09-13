#!/usr/bin/env bash
# Install dovi_tool and hdr10plus_tool for the Tdarr container.
#
#   scripts/tdarr-hdr-tools.sh
#
# The Tdarr shrink flow (tdarr/flows/) re-encodes with NVENC, which drops
# Dolby Vision RPUs and HDR10+ dynamic metadata. These two tools lift that
# metadata off the source and inject it into the new stream, the same way
# scripts/transcode.sh does on the host.
#
# The host's own copies cannot be reused: Arch builds them against glibc
# 2.44 and the Tdarr image is Ubuntu 24.04 with glibc 2.39. Upstream ships
# static musl builds that run anywhere, so those are fetched, checked
# against the release digests pinned below, and mounted read-only into the
# container at /opt/hdr-tools (see docker-compose.tdarr.yml).
#
# Versions track the host packages so both paths behave the same. Bump the
# version and digest together; the digests are on each GitHub release page.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env
DEST="${COMMON_CONFIG}/tdarr/bin"

TOOLS=(
  "dovi_tool 2.3.3 5dae82cb2becd3b9fd726127f936a8d32635e60746d16238fdfded12aa05988c"
  "hdr10plus_tool 1.7.2 06385f37a639d61ba21d4be3150c863846933bc3b58110e094d8fc8f1c2249f2"
)

mkdir -p "$DEST"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

for row in "${TOOLS[@]}"; do
  read -r name ver sha <<<"$row"
  if [ -x "$DEST/$name" ] && "$DEST/$name" --version 2>/dev/null | grep -qx "$name $ver"; then
    echo "$name $ver already installed"
    continue
  fi
  tarball="$name-$ver-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL -o "$tmp/$tarball" "https://github.com/quietvoid/$name/releases/download/$ver/$tarball"
  echo "$sha  $tmp/$tarball" | sha256sum -c --quiet -
  tar -xzf "$tmp/$tarball" -C "$tmp" "./$name"
  install -m 0755 "$tmp/$name" "$DEST/$name"
  echo "$name $ver installed"
done
