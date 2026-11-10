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
#   6. The Proxmox auto-updater is succeeding: its last-success marker exists and
#      is < UPDATE_STALE_DAYS old, and its last unit run did not fail (unless a
#      later success superseded it). Added 2026-11-10 after the updater failed
#      silently on every run 2026-09-06..11-06. Skipped (BHC_SKIP_UPDATER_CHECK=1)
#      only when proxmox-monthly-update calls this script as its pre-flight gate.
#      Also warns when the post-update guest restore list outlives RESTORE_GRACE_MIN
#      (proxmox-guest-restore.service did not bring the lab guests back).
#
# Test seams: BHC_LOG, BHC_UPDATE_MARKER and BHC_RESTORE_LIST override the paths below, so the
# whole script can run end to end against a sandbox without touching live state.
#
# Exit: 0 = all healthy, 1 = warning(s), 2 = failure(s).
# Output is appended to /var/log/backup-health-check.log and echoed to stdout,
# so a systemd timer's journal and OpenClaw can both consume it.
# USB-touching commands are wrapped in `timeout` so a sick bridge can't hang
# the script even when it is run outside the systemd unit's TimeoutStartSec.

set -uo pipefail
export LC_ALL=C   # stable numeric formatting for find's %T@ epoch values

LOG=${BHC_LOG:-/var/log/backup-health-check.log}
RESTIC_MOUNT=/mnt/backup-files
RESTIC_REPO=/mnt/backup-files/restic
VEEAM_DIR=/mnt/backup-images
RESTIC_STALE_HOURS=36          # restic task runs at least daily
VEEAM_STALE_HOURS=48           # Veeam runs daily incrementals; 48h leaves margin
SPACE_WARN=85                  # percent used -> warning
SPACE_FAIL=95                  # percent used -> failure
IO_TIMEOUT=60                  # seconds — cap on any single USB-touching command
UPDATE_MARKER=${BHC_UPDATE_MARKER:-/var/lib/proxmox-monthly-update/last-success}
UPDATE_LOG=/var/log/proxmox-monthly-update.log
UPDATE_UNIT=proxmox-monthly-update.service
UPDATE_STALE_DAYS=20           # runs on the 6th + 20th (<= 17 days apart): one missed run trips this
RESTORE_LIST=${BHC_RESTORE_LIST:-/var/lib/proxmox-monthly-update/restore-guests}
RESTORE_GRACE_MIN=60           # the list lives ~2 min (reboot +1m, then boot) when restore works

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

# check_updater <marker> <unit-result> <unit-exit-epoch> <update-log> <stale-days>
# Ground truth is the marker the updater writes only after a completed run. Every
# unknown (missing, malformed, future-dated) WARNs; nothing resolves to "all clear".
check_updater() {
  local marker="$1" result="$2" exit_epoch="$3" ulog="$4" stale_d="$5" last="" age_s lastfail
  # Exactly one line of digits (command substitution drops the final newline).
  # Nothing is stripped from inside, so "123\n456" stays malformed.
  if [ -r "$marker" ]; then
    last=$(head -c 33 "$marker" 2>/dev/null)
  fi
  # A failed unit run alarms, unless a later success (e.g. a manual run) superseded it.
  if [ -n "$result" ] && [ "$result" != "success" ]; then
    if [[ "$last" =~ ^[0-9]{1,12}$ ]] && [[ "$exit_epoch" =~ ^[0-9]{1,12}$ ]] && [ "$last" -gt "$exit_epoch" ]; then
      ok "auto-update unit result '$result' was superseded by a later successful run"
    else
      lastfail=$(grep -E '\[FAIL\]' "$ulog" 2>/dev/null | tail -1 | sed -E 's/^[^ ]+ \[FAIL\] +//' | cut -c1-160)
      warn "last proxmox-monthly-update run failed (result=$result): ${lastfail:-see $ulog}"
    fi
  fi
  if [ ! -e "$marker" ]; then
    warn "no successful auto-update recorded ($marker missing) — host may be falling behind on patches"
    return
  fi
  if ! [[ "$last" =~ ^[0-9]{1,12}$ ]]; then
    warn "auto-update marker $marker is unreadable or malformed"
    return
  fi
  age_s=$(( NOW - last ))
  if [ "$age_s" -lt -300 ]; then
    warn "auto-update marker is $(( -age_s / 60 )) min in the future — clock skew"
  elif [ "$age_s" -gt $(( stale_d * 86400 )) ]; then
    warn "last successful auto-update was $(( age_s / 86400 ))d ago (> ${stale_d}d) — host is falling behind on patches"
  else
    ok "last successful auto-update $(( age_s / 86400 ))d ago"
  fi
}

# check_guest_restore <list> <grace-min>
# proxmox-guest-restore.service archives the list only after every guest it names
# is running, so a list that outlives the grace window means guests stayed down
# (restore failed, refused a stale list, or never ran).
check_guest_restore() {
  local list="$1" grace="$2" mtime age_m n
  if [ ! -e "$list" ]; then
    ok "no pending post-update guest restore"
    return
  fi
  mtime=$(stat -c %Y "$list" 2>/dev/null)
  if ! [[ "$mtime" =~ ^[0-9]{1,12}$ ]]; then
    warn "guest restore list $list exists but its age is unreadable — check proxmox-guest-restore.service"
    return
  fi
  age_m=$(( (NOW - mtime) / 60 ))
  n=$(grep -Ec '^(CT|VM) ' "$list" 2>/dev/null) || n=0
  if [ "$age_m" -lt -5 ]; then
    warn "guest restore list $list is dated $(( -age_m )) min in the future (clock skew) — check proxmox-guest-restore.service"
  elif [ "$age_m" -gt "$grace" ]; then
    warn "$n guest(s) from the last update reboot were not restored (list $list is ${age_m} min old) — see journalctl -u proxmox-guest-restore; start them by hand, then delete the list"
  else
    ok "guest restore list written ${age_m} min ago ($n guest(s)) — reboot/restore in progress"
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

# --- 6. Proxmox auto-update health (see header). ---
if [ "${BHC_SKIP_UPDATER_CHECK:-0}" = 1 ]; then
  log "       skipping auto-update check (pre-flight call from proxmox-monthly-update)"
else
  upd_result=$(systemctl show "$UPDATE_UNIT" -p Result --value 2>/dev/null) || upd_result=""
  upd_exit_ts=$(systemctl show "$UPDATE_UNIT" -p ExecMainExitTimestamp --value 2>/dev/null) || upd_exit_ts=""
  upd_exit_epoch=""
  if [ -n "$upd_exit_ts" ]; then
    upd_exit_epoch=$(date -d "$upd_exit_ts" +%s 2>/dev/null) || upd_exit_epoch=""
  fi
  check_updater "$UPDATE_MARKER" "$upd_result" "$upd_exit_epoch" "$UPDATE_LOG" "$UPDATE_STALE_DAYS"
  check_guest_restore "$RESTORE_LIST" "$RESTORE_GRACE_MIN"
fi

# --- summary ---
log "=== SUMMARY: $FAIL failure(s), $WARN warning(s) ==="
if [ "$FAIL" -gt 0 ]; then
  exit 2
elif [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
