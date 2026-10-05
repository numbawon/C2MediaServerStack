#!/usr/bin/env bash
# The night shift. Brings a worker node up to date while nobody is watching,
# and when the update touched something only a reboot can pick up (kernel,
# libc, systemd, firmware, the container runtime), books that reboot for the
# quiet hour instead of leaving a stale kernel running for weeks.
#
# Runs as root from mediastack-node-update.timer. Installed on the workers
# by ansible/playbooks/node-maintenance.yml, which also writes
# /etc/mediastack-node.conf. These nodes have no checkout of this repo, so
# everything here is self-contained.
#
# Order of operations, and why:
#   1. Snapshot the root subvolume first. Arch is rolling; the rollback for
#      "an update broke boot" is a snapshot taken BEFORE it, not a prayer.
#   2. Re-rank the pacman mirrors (reflector) so the upgrade pulls from
#      whatever is fast and fresh today, not whatever was best at install.
#      A failed or tiny result never replaces the working list.
#   3. Keyring, then the full upgrade. Keyring first because a stale
#      keyring is the usual reason an unattended `pacman -Syu` dies halfway.
#   4. Decide whether a reboot is actually needed. Reboot only when it
#      matters, so a quiet week costs nothing.
#   5. Trim the package cache: keep the last two versions of each package
#      (enough to downgrade after a bad update), drop the rest and any
#      leftover partial downloads from interrupted runs.
#   6. Prune Docker images no container uses. Updates leave the previous
#      image behind every time a service moves to a new tag. Only images
#      with no container at all (running OR stopped) are removed, so
#      nothing in use is touched; the cost is a re-pull if Swarm later
#      reschedules a service onto this node.
#   7. Report config drift. A package upgrade that finds a config file you
#      changed leaves the new default beside it as <file>.pacnew instead of
#      overwriting your edit, and nothing ever merges it. They are listed in
#      the log and counted as a metric. Never merged unattended: picking a
#      side for /etc/fstab or sshd_config is a human decision.
#   8. Book the reboot with `shutdown -r`, at REBOOT_AT. The post-boot check
#      (mediastack-node-postboot.sh) then proves the node came back.
#   9. Write the outcome as Prometheus textfile metrics so a node that
#      silently stopped updating shows up as an alert, not as silence.
set -euo pipefail

CONF=/etc/mediastack-node.conf
# REBOOT_AT is an HH:MM for `shutdown -r`. Defaults are overridden by CONF.
REBOOT_AT=03:30
SNAPSHOT_KEEP=3
# Mirror ranking. MIRROR_COUNTRY is a reflector --country value.
MIRROR_COUNTRY=US
MIRROR_KEEP=8
# Set DOCKER_PRUNE=0 in /etc/mediastack-node.conf to keep unused images.
DOCKER_PRUNE=1
# Packages that only take effect after a reboot. Matched against the names
# of packages this run actually upgraded.
REBOOT_PKGS='^(linux|linux-lts|linux-zen|linux-hardened|linux-firmware.*|amd-ucode|intel-ucode|systemd|systemd-libs|glibc|docker|containerd|runc|mesa)$'
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

TEXTFILE_DIR=/var/lib/docker/volumes/node_exporter_textfile/_data
LOCK=/run/mediastack-node-update.lock
exec 9>"$LOCK"
flock -n 9 || { echo "another update run is active, exiting"; exit 0; }

log() { echo "[node-update] $*"; }

pacnew_list() {
  find /etc /boot -xdev \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort
}
count_pacnew() { pacnew_list | wc -l; }

write_metrics() {
  # $1 success(0/1) $2 pending-reboot(0/1) $3 packages upgraded
  [ -d "$TEXTFILE_DIR" ] || return 0
  local tmp="$TEXTFILE_DIR/.node_update.prom.$$"
  cat >"$tmp" <<M
# HELP mediastack_node_update_last_run_timestamp_seconds Last unattended update run.
# TYPE mediastack_node_update_last_run_timestamp_seconds gauge
mediastack_node_update_last_run_timestamp_seconds $(date +%s)
# HELP mediastack_node_update_success 1 if the last unattended update run succeeded.
# TYPE mediastack_node_update_success gauge
mediastack_node_update_success $1
# HELP mediastack_node_update_reboot_pending 1 if a reboot is booked or still needed.
# TYPE mediastack_node_update_reboot_pending gauge
mediastack_node_update_reboot_pending $2
# HELP mediastack_node_update_packages_upgraded Packages upgraded in the last run.
# TYPE mediastack_node_update_packages_upgraded gauge
mediastack_node_update_packages_upgraded $3
# HELP mediastack_node_pacnew_files Config files with an unmerged .pacnew or .pacsave beside them.
# TYPE mediastack_node_pacnew_files gauge
mediastack_node_pacnew_files $(count_pacnew)
# HELP mediastack_node_pacman_cache_bytes Size of /var/cache/pacman/pkg after the last trim.
# TYPE mediastack_node_pacman_cache_bytes gauge
mediastack_node_pacman_cache_bytes $(du -sb /var/cache/pacman/pkg 2>/dev/null | awk '{print $1+0}')
M
  mv "$tmp" "$TEXTFILE_DIR/node_update.prom"
}

UPGRADED=0
fail() { log "FAILED: $*"; write_metrics 0 "$(reboot_needed_now && echo 1 || echo 0)" "$UPGRADED"; exit 1; }

# The running kernel's modules disappear from /usr/lib/modules once its
# package is replaced, which is the dependable "kernel was updated" signal.
reboot_needed_now() {
  [ ! -d "/usr/lib/modules/$(uname -r)" ] || [ -e /run/mediastack-reboot-needed ]
}

[ -e /var/lib/pacman/db.lck ] && fail "pacman database is locked"

# These nodes resolve DNS through the manager's Pi-hole alone. When the
# manager restarts its stack, name lookups on the workers fail for a few
# minutes, and a pacman run started inside that window dies on "could not
# resolve host" (seen 2026-10-02 morning, both nodes). Wait it out rather
# than fail an otherwise healthy update.
wait_for_dns() {
  local host deadline=$(( $(date +%s) + 600 ))
  host=$(grep -m1 '^Server' /etc/pacman.d/mirrorlist | sed -E 's#^Server *= *https?://([^/]+).*#\1#')
  until getent hosts "$host" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    log "cannot resolve $host yet, waiting"; sleep 15
  done
}
wait_for_dns || fail "no DNS for the mirrors after 10 minutes"

log "snapshotting / before the update"
if [ -d /.snapshots ]; then
  snap="/.snapshots/pre-update-$(date +%Y%m%d-%H%M%S)"
  btrfs subvolume snapshot -r / "$snap" >/dev/null || fail "snapshot failed"
  # shellcheck disable=SC2012
  ls -1d /.snapshots/pre-update-* 2>/dev/null | head -n -"$SNAPSHOT_KEEP" | while read -r old; do
    btrfs subvolume delete "$old" >/dev/null || true
  done
else
  log "no /.snapshots here, continuing without a rollback point"
fi

rank_mirrors() {
  command -v reflector >/dev/null || { log "reflector not installed yet, keeping the current mirror list"; return 0; }
  local new=/run/mediastack-mirrorlist.new
  # https only, recently synced, then measured by download rate. The fast
  # ones win, which is the re-measuring.
  if reflector --country "$MIRROR_COUNTRY" --protocol https --age 24 --latest 25 \
        --sort rate --number "$MIRROR_KEEP" --download-timeout 10 --save "$new" 2>/dev/null \
     && [ "$(grep -c '^Server' "$new")" -ge 3 ]; then
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.pre-rank
    install -m 0644 "$new" /etc/pacman.d/mirrorlist
    log "mirrors re-ranked: $(grep -c '^Server' /etc/pacman.d/mirrorlist) kept, fastest $(grep -m1 '^Server' /etc/pacman.d/mirrorlist | awk '{print $3}')"
  else
    log "mirror ranking failed or came back thin, keeping the current list"
  fi
  rm -f "$new"
}
rank_mirrors

pacman -Sy --noconfirm archlinux-keyring >/dev/null || fail "keyring refresh failed"
mapfile -t TO_UPGRADE < <(pacman -Qu | awk '{print $1}')
UPGRADED=${#TO_UPGRADE[@]}
log "${UPGRADED} package(s) to upgrade"

if [ "$UPGRADED" -gt 0 ] || ! command -v reflector >/dev/null || ! command -v paccache >/dev/null || ! command -v smartctl >/dev/null; then
  # reflector rides along on the full upgrade (not a separate -S) so it is
  # never installed against a half-synced package database.
  pacman -Su --noconfirm --needed reflector pacman-contrib smartmontools || fail "pacman -Su failed"
  # Anything that needs the new binary running is picked up only on reboot;
  # remember the reason across this process's lifetime.
  for p in "${TO_UPGRADE[@]}"; do
    if [[ "$p" =~ $REBOOT_PKGS ]]; then
      log "reboot-relevant package upgraded: $p"
      touch /run/mediastack-reboot-needed
    fi
  done
fi

trim_cache() {
  command -v paccache >/dev/null || return 0
  # -rk2: keep two versions of every installed package. -ruk0: of packages
  # no longer installed, keep none. Both only ever delete cache files.
  paccache -rk2 >/dev/null 2>&1 || log "paccache keep-2 pass failed (non-fatal)"
  paccache -ruk0 >/dev/null 2>&1 || log "paccache uninstalled pass failed (non-fatal)"
  # download-XXXX directories are partial downloads. pacman removes its own
  # on success, so any older than a day belong to a run that was killed.
  find /var/cache/pacman/pkg -maxdepth 1 -type d -name 'download-*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true
  log "package cache is now $(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')"
}
trim_cache

prune_images() {
  [ "$DOCKER_PRUNE" = "1" ] || return 0
  docker info >/dev/null 2>&1 || { log "docker not answering, skipping image prune"; return 0; }
  # -a: every image no container references, not just untagged ones. Never
  # volumes, networks or containers.
  local out
  out=$(docker image prune -af 2>&1) || { log "docker image prune failed (non-fatal)"; return 0; }
  log "docker image prune: $(grep -i 'reclaimed' <<<"$out" || echo 'nothing to reclaim')"
}
prune_images

report_pacnew() {
  local list
  list=$(pacnew_list)
  if [ -n "$list" ]; then
    log "config drift, $(wc -l <<<"$list") unmerged file(s), review with pacdiff:"
    while read -r f; do log "  $f"; done <<<"$list"
  else
    log "no unmerged .pacnew or .pacsave files"
  fi
}
report_pacnew

# /run is tmpfs: the marker deliberately dies with the reboot it asked for.
if reboot_needed_now; then
  if [ -e /run/systemd/shutdown/scheduled ]; then
    log "a reboot is already booked"
  else
    log "booking reboot for ${REBOOT_AT}"
    shutdown -r "$REBOOT_AT" "mediastack: reboot after package updates" || fail "could not book reboot"
  fi
  write_metrics 1 1 "$UPGRADED"
else
  log "no reboot needed"
  write_metrics 1 0 "$UPGRADED"
fi
log "done"
