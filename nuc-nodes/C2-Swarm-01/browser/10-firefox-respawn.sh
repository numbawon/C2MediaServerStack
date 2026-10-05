#!/usr/bin/with-contenv bash
# Keep Firefox alive on the remote desktop.
#
# The desktop in this image starts Firefox once from its autostart file and
# never again. Close the last tab and Firefox exits, which leaves a black
# screen with nothing to click: the one app on the desktop is gone. This
# makes the autostart a loop, so closing the browser just opens a fresh
# window a moment later.
#
# Runs as root at container start (the image executes everything in
# /custom-cont-init.d). Two places need it:
#   /defaults/...        what a brand-new profile copies on its first start
#   /config/.config/...  the copy an existing profile already made, which
#                        the image never refreshes on its own
# The sleep is a brake, not a delay: if Firefox ever dies instantly on start
# (a corrupt profile, say), this retries every few seconds instead of
# spinning.
set -eu
# shellcheck disable=SC2016  # ${FIREFOX_CLI} must stay literal in the generated file
LOOP='#!/bin/bash

while true; do
  /usr/bin/firefox ${FIREFOX_CLI}
  sleep 2
done'

for f in /defaults/autostart /defaults/autostart_wayland; do
  [ -d "$(dirname "$f")" ] && printf '%s\n' "$LOOP" > "$f"
done
for d in /config/.config/labwc /config/.config/openbox; do
  if [ -f "$d/autostart" ]; then
    printf '%s\n' "$LOOP" > "$d/autostart"
    chown abc:abc "$d/autostart" 2>/dev/null || true
  fi
done
