# Zork I/II/III in the browser: ttyd wraps frotz the same way a shell login
# used to run frotz directly instead of bash. Story files come from Microsoft
# and Activision's November 2025 MIT-licensed release of the original ZIL
# source (github.com/historicalsource/zork{1,2,3}) -- COMPILED/zorkN.z3 in
# each repo is the pre-built Z-machine story file, so no ZILF compile step
# is needed here, just a pinned, checksummed download.
FROM alpine:3.22

RUN apk add --no-cache frotz ca-certificates wget

# Pinned to a specific release, not `latest`; sha256 verified so a
# compromised or replaced release asset fails the build instead of
# silently running.
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
RUN wget -qO /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && echo "${TTYD_SHA256}  /usr/local/bin/ttyd" | sha256sum -c - \
    && chmod +x /usr/local/bin/ttyd

# Each ARG is a commit, not a branch -- these repos have no tags/releases,
# so a commit is the only reproducible reference. sha256 of the story file
# itself is checked too: these are Infocom's original 1980s binaries,
# unchanged since; a hash mismatch means the wrong file arrived, not that
# a new release shipped.
ARG ZORK1_COMMIT=97b7b3d68c075dd9af7da499c3e9690ada3471fd
ARG ZORK2_COMMIT=3da9661098809788a99cef00f00c865c6c204f96
ARG ZORK3_COMMIT=3ec9ed412b5f3cafe65d83c727d07db1fe4a86a8
ARG ZORK1_SHA256=37084966477dff679282de42974b2077156b1bd68fad92a65d4ea94d8eb64d79
ARG ZORK2_SHA256=3ae7d5558943e9721f3e4b273c8a7faec1a03a604e1ae4ee1cde472c21cb24ac
ARG ZORK3_SHA256=b637a242865d059890184164ce8dec28554cc80901dcbf26c740b2d1ed0d4eb8

RUN mkdir -p /games \
    && wget -qO /games/zork1.z3 "https://raw.githubusercontent.com/historicalsource/zork1/${ZORK1_COMMIT}/COMPILED/zork1.z3" \
    && wget -qO /games/zork2.z3 "https://raw.githubusercontent.com/historicalsource/zork2/${ZORK2_COMMIT}/COMPILED/zork2.z3" \
    && wget -qO /games/zork3.z3 "https://raw.githubusercontent.com/historicalsource/zork3/${ZORK3_COMMIT}/COMPILED/zork3.z3" \
    && echo "${ZORK1_SHA256}  /games/zork1.z3" | sha256sum -c - \
    && echo "${ZORK2_SHA256}  /games/zork2.z3" | sha256sum -c - \
    && echo "${ZORK3_SHA256}  /games/zork3.z3" | sha256sum -c -

# Chrome on Android has a known, unfixed xterm.js/ttyd bug (tsl0922/
# ttyd#191, closed "not planned"): the fit calculation on tall mobile
# viewports reports far more terminal rows than the screen can actually
# show at a normal font size. frotz's opening screen positions itself
# with an absolute cursor move computed from that reported row count
# (confirmed against the real WebSocket frames: `ESC[109d`/`ESC[117d`
# on a 117-row terminal, i.e. "near the bottom"), so on a normal ~24-row
# terminal that convention looks completely normal, but on a
# wrongly-inflated 100+ row one it leaves most of the screen blank with
# the actual text crammed at the very bottom.
#
# The real fix has to stop the terminal from reporting that many rows
# in the first place -- ttyd client options (fontSize, rendererType)
# only change how a cell is measured, not the row-count bug itself,
# confirmed by testing both and neither helping. This caps the
# container's CSS height, but only under a max-width media query so
# desktop/tablet sessions (where this bug does not happen) keep using
# the full window instead of being shrunk for no reason.
#
# Generated at build time, not vendored, so it always matches whatever
# TTYD_VERSION is pinned above: briefly runs ttyd to fetch its own
# default index.html, then injects the override.
RUN (ttyd -p 19999 true &) \
    && sleep 1 \
    && wget -qO /ttyd-index.html http://127.0.0.1:19999/ \
    && pkill ttyd \
    && sed -i 's|</head>|<style>@media (max-width: 1000px){#terminal-container{max-height:640px!important}}</style></head>|' /ttyd-index.html \
    && grep -q "max-width: 1000px" /ttyd-index.html

# frotz refuses outright to run as root ("I won't run as root!"), so this
# needs a real non-root user regardless of the stack's usual PUID/PGID
# convention -- there is nothing here to chown against a bind mount, no
# persistent state at all, so a fixed in-image user is fine.
RUN adduser -D -u 1000 player
USER player

# One image, three services in docker-stack.yml (zork-1/2/3), each
# supplying its own `command:` -- the game file and the -b base path both
# differ per service, so neither belongs baked into the image. The
# landing page (zork/landing) is what actually picks which one a visitor
# lands on; there is no in-terminal menu here anymore.
#
# -W: ttyd is read-only by default (keystrokes silently dropped without
# it), same gotcha as the host terminal service. No -t fontFamily=... for
# the same reason documented there: a font missing on the client degrades
# to a 0-size xterm.js grid, not a fallback font.
EXPOSE 7681
ENTRYPOINT ["ttyd", "-I", "/ttyd-index.html"]
