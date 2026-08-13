#!/bin/bash
# backup-health-check.sh — daily health check of the OWC-hosted Windows backups.
#
# Runs on the Proxmox host. Catches the silent-failure modes that plagued the
# previous (ASMedia) enclosure: unmounted drives, full disks, stalled backup
# jobs, and USB bridge errors.
#
# Checks (no secrets required):
#   1. OWC backup mounts are mounted as real ext4 block devices (not the autofs
#      stub, and not the root fs falling through when the drive is absent)
#   2. Free space on each backup drive
#   3. restic repo present + newest snapshot is recent (backup job still running)
#   4. Veeam job present + newest .vbk/.vib restore point is recent
#   5. No USB bridge resets / I/O errors in the kernel log in the last 24h
#
# Exit: 0 = all healthy, 1 = warning(s), 2 = failure(s).
# Output is appended to /var/log/backup-health-check.log and echoed to stdout,
# so a systemd timer's journal and OpenClaw can both consume it.
# USB-touching commands are wrapped in `timeout` so a sick bridge can't hang
# the script even when it is run outside the systemd unit's TimeoutStartSec.

set -uo pipefail
export LC_ALL=C   # stable numeric formatting for find's %T@ epoch values

LOG=/var/log/backup-health-check.log
RESTIC_MOUNT=/mnt/backup-files
RESTIC_REPO=/mnt/backup-files/restic
VEEAM_DIR=/mnt/backup-images
RESTIC_STALE_HOURS=36          # restic task runs at least daily
VEEAM_STALE_HOURS=48           # Veeam runs daily incrementals; 48h leaves margin
SPACE_WARN=85                  # percent used -> warning
SPACE_FAIL=95                  # percent used -> failure
IO_TIMEOUT=60                  # seconds — cap on any single USB-touching command

WARN=0
FAIL=0
NOW=$(date +%s)                # single reference instant for all freshness checks

# Ensure the log is writable; if not (e.g. root fs full), fall back to stderr
# only and flag it — a degraded alerting path is itself a failure.
if ! { : >> "$LOG"; } 2>/dev/null; then
  echo "$(date -Is) [FAIL] cannot write log $LOG — /var full or permissions?" >&2
  LOG=/dev/null
  FAIL=$((FAIL + 1))
fi

log()  { echo "$(date -Is) $*" | tee -a "$LOG"; }
ok()   { log "[OK]   $*"; }
warn() { log "[WARN] $*"; WARN=$((WARN + 1)); }
bad()  { log "[FAIL] $*"; FAIL=$((FAIL + 1)); }

# Report freshness of the newest item given its epoch mtime. Compares in
# seconds (not floored hours) so a 36h59m-old backup is not rounded to 36h
# and falsely passed. Guards against clock skew (future timestamp).
check_age() {
  local label="$1" epoch="${2%.*}" stale_h="$3" age_s stale_s
  age_s=$(( NOW - epoch ))
  stale_s=$(( stale_h * 3600 ))
  if [ "$age_s" -lt 0 ]; then
    warn "$label newest item has a future timestamp ($(( age_s / 3600 ))h) — clock skew"
  elif [ "$age_s" -gt "$stale_s" ]; then
    warn "$label newest item is $(( age_s / 3600 ))h old (> ${stale_h}h) — backup job may have stalled"
  else
    ok "$label newest item is $(( age_s / 3600 ))h old"
  fi
}

log "=== backup health check START ==="

# --- 1. mount checks: each backup mount must be a REAL ext4 block-device mount.
# Use --mountpoint (not --target): --target would walk up to the root fs and
# falsely report ext4 when the OWC drive is absent and the path is a bare dir.
# Filter with -t ext4: x-systemd.automount stacks an autofs sentinel and the
# real ext4 mount at the same path. Without the filter, findmnt returns BOTH
# entries on separate lines and $fstype becomes "autofs\next4" — failing the
# equality check on a healthy mount. (Surfaced post Proxmox 9.2 upgrade.)
declare -A MOUNT_OK
for mp in "$RESTIC_MOUNT" "$VEEAM_DIR"; do
  timeout "$IO_TIMEOUT" ls "$mp" >/dev/null 2>&1   # trigger x-systemd.automount
  fstype=$(findmnt -nro FSTYPE -t ext4 --mountpoint "$mp" 2>/dev/null | head -1)
  src=$(findmnt -nro SOURCE -t ext4 --mountpoint "$mp" 2>/dev/null | head -1)
  if [ "$fstype" = "ext4" ] && [ -b "$src" ]; then
    ok "mount $mp is ext4 on $src"
    MOUNT_OK[$mp]=1
  else
    bad "mount $mp not available (fstype='${fstype:-none}' src='${src:-none}') — OWC drive missing or automount failed"
    MOUNT_OK[$mp]=0
  fi
done

# --- 2. free space (only meaningful when the mount is real) ---
for mp in "$RESTIC_MOUNT" "$VEEAM_DIR"; do
  if [ "${MOUNT_OK[$mp]:-0}" -ne 1 ]; then
    log "       skipping space check for $mp — not mounted"
    continue
  fi
  use=$(timeout "$IO_TIMEOUT" df --output=pcent "$mp" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$use" ]; then
    warn "could not read free space for $mp (timed out or df error)"
  elif [ "$use" -ge "$SPACE_FAIL" ]; then
    bad "$mp is ${use}% full (>= ${SPACE_FAIL}%)"
  elif [ "$use" -ge "$SPACE_WARN" ]; then
    warn "$mp is ${use}% full (>= ${SPACE_WARN}%)"
  else
    ok "$mp is ${use}% full"
  fi
done

# --- 3. restic repo present + freshness ---
# `find` is captured separately from sort/head — putting them in one pipeline
# masks find's exit status. With pipefail enabled, sort returns SIGPIPE (141)
# when head -1 closes the pipe early, and the rightmost non-zero status wins —
# so a timed-out find that emitted partial results would silently look like a
# successful scan, and a happens-to-be-fresh partial result would pass freshness.
if [ "${MOUNT_OK[$RESTIC_MOUNT]:-0}" -ne 1 ]; then
  log "       skipping restic check — $RESTIC_MOUNT not mounted"
elif [ ! -f "$RESTIC_REPO/config" ]; then
  bad "restic repo config missing at $RESTIC_REPO/config"
else
  restic_scan=$(timeout "$IO_TIMEOUT" find "$RESTIC_REPO/snapshots" -type f -printf '%T@\n' 2>/dev/null)
  scan_exit=$?
  if [ "$scan_exit" -ne 0 ]; then
    bad "restic snapshot scan failed (find exit=$scan_exit, likely timeout > ${IO_TIMEOUT}s)"
  elif [ -z "$restic_scan" ]; then
    bad "restic repo has no snapshots"
  else
    newest=$(printf '%s\n' "$restic_scan" | sort -rn | head -1)
    check_age "restic snapshot" "$newest" "$RESTIC_STALE_HOURS"
  fi
fi

# --- 4. Veeam present + freshness (.vbk/.vib only — a .vbm metadata-only
# update must not make a stalled job look fresh). Same split-pipeline pattern
# as the restic block: capture find's exit status separately from sort/head. ---
if [ "${MOUNT_OK[$VEEAM_DIR]:-0}" -ne 1 ]; then
  log "       skipping Veeam check — $VEEAM_DIR not mounted"
else
  veeam_scan=$(timeout "$IO_TIMEOUT" find "$VEEAM_DIR" -type f \( -name '*.vbk' -o -name '*.vib' \) -printf '%T@\n' 2>/dev/null)
  scan_exit=$?
  if [ "$scan_exit" -ne 0 ]; then
    bad "Veeam scan failed (find exit=$scan_exit, likely timeout > ${IO_TIMEOUT}s)"
  elif [ -z "$veeam_scan" ]; then
    bad "Veeam directory $VEEAM_DIR has no .vbk/.vib restore points"
  else
    vnewest=$(printf '%s\n' "$veeam_scan" | sort -rn | head -1)
    check_age "Veeam restore point" "$vnewest" "$VEEAM_STALE_HOURS"
  fi
fi

# --- 5. USB bridge errors in the last 24h. journalctl status is checked
# directly (if-assignment) so a journalctl failure cannot be masked into a
# false [OK]. ---
if usb_log=$(journalctl -k --since "1 day ago" --no-pager 2>/dev/null); then
  usberr=$(printf '%s\n' "$usb_log" | grep -cE 'reset SuperSpeed|I/O error, dev sd' || true)
  if [ "${usberr:-0}" -gt 0 ]; then
    warn "$usberr USB reset / I/O-error event(s) in the kernel log in the last 24h — inspect the enclosure"
  else
    ok "no USB reset / I/O-error events in the last 24h"
  fi
else
  warn "could not read kernel log (journalctl failed) — USB error check skipped"
fi

# --- summary ---
log "=== SUMMARY: $FAIL failure(s), $WARN warning(s) ==="
if [ "$FAIL" -gt 0 ]; then
  exit 2
elif [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
