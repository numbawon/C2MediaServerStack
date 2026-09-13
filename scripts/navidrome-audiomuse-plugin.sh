#!/usr/bin/env bash
# Install the AudioMuse-AI plugin into Navidrome's plugin folder.
#
#   scripts/navidrome-audiomuse-plugin.sh
#
# Navidrome loads plugins from /data/plugins, which is
# .appdata/navidrome/plugins on the host. The .ndp is fetched from the
# plugin's GitHub release and checked against the digest pinned below
# before it replaces anything.
#
# Pinned as a PAIR with the core image in docker-compose.audiomuse.yml:
# upstream names a core/plugin/Navidrome version mismatch as the most
# common cause of errors. Bump both together; the digest is on the
# release page.
#
# Navidrome does not autoreload plugins here (ND_PLUGINS_AUTORELOAD is
# off), so a changed file is picked up on the next restart:
#   docker service update --force mediastack_navidrome
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

VERSION=v10
SHA256=c138e9af16f097d8cd07ac957fb8a49d91a7da066e5b4a1457cadbd479aa10a7
DEST="${COMMON_CONFIG}/navidrome/plugins/audiomuseai.ndp"

if [ -f "$DEST" ] && echo "$SHA256  $DEST" | sha256sum -c --quiet - 2>/dev/null; then
  echo "audiomuseai.ndp $VERSION already installed"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT
curl -fsSL -o "$tmp" "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin/releases/download/$VERSION/audiomuseai.ndp"
echo "$SHA256  $tmp" | sha256sum -c --quiet -
install -m 0644 "$tmp" "$DEST"
echo "audiomuseai.ndp $VERSION installed; restart Navidrome to load it"
