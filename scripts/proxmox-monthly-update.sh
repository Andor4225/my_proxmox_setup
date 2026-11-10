#!/bin/bash
# proxmox-monthly-update.sh — automated semi-monthly Proxmox VE upgrade.
#
# Runs on the Proxmox host via systemd timer on the 6th and 20th of each month
# at 02:30 CT. Mirrors the manual upgrade procedure executed 2026-05-23 for
# 9.1.1 → 9.2.2:
#
#   1. Pre-flight   — free space, no in-flight backup, OWC mounts healthy
#   2. Snapshot     — running + stopped CTs/VMs (skip templates), /etc backup
#   3. Upgrade      — apt full-upgrade with force-confold / force-confdef
#   4. Reboot       — ONLY if a newer kernel is installed than the one running
#                     (PVE has no /var/run/reboot-required; see Phase 4). The running guests
#                     are recorded first; proxmox-guest-restore.service restarts
#                     them after boot (fatal, with no reboot, if recording fails)
#   5. Cleanup      — prune auto_update_* snapshots older than 60 days
#
# Verification after a reboot is intentionally not done inside this script:
# backup-health-check.timer fires daily at ~09:00 (with RandomizedDelaySec),
# and OpenClaw runs proxmox health checks 3x/day — both consume the post-boot
# state and alert to Discord on any non-zero exit. Doing it here would
# duplicate the existing monitoring without adding signal.
#
# Exit codes:
#   0 — success (with or without a reboot scheduled)
#   1 — pre-flight failure; no changes applied
#   2 — apt failure; snapshots intact for manual rollback
#
# Output: appended to /var/log/proxmox-monthly-update.log
# Lock:   /var/run/proxmox-monthly-update.lock (flock — no double-firing)
# Args:
#   --dry-run   pre-flight + apt update + apt list --upgradable; no changes

set -uo pipefail
export LC_ALL=C

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "")        DRY_RUN=0 ;;
  *)         echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

LOG=/var/log/proxmox-monthly-update.log
LOCKFILE=/var/run/proxmox-monthly-update.lock
DATE_TAG=$(date +%Y-%m-%d)
SNAPSHOT_TAG=$(date +%Y_%m)
SNAPSHOT_NAME="auto_update_${SNAPSHOT_TAG}"
PREUPGRADE_DIR="/root/preupgrade-${DATE_TAG}"
MIN_BOOT_MB=500
MIN_VAR_GB=5
HEALTH_CHECK=/usr/local/sbin/backup-health-check.sh
SNAPSHOT_RETENTION_DAYS=60
# Success marker (epoch) - written ONLY after a completed run; backup-health-check
# alarms when it is missing or stale, so a silently failing updater gets noticed.
MARKER_DIR=/var/lib/proxmox-monthly-update
MARKER="$MARKER_DIR/last-success"
# Guests running when a reboot is scheduled; proxmox-guest-restore.service starts
# them again after boot (lab guests are onboot=0 and would otherwise stay down).
RESTORE_LIST="$MARKER_DIR/restore-guests"
# Backup-in-flight gate: SMB share roots, and how long they must have been quiet.
BACKUP_MOUNTS=(/mnt/backup-files /mnt/backup-images)
BACKUP_QUIET_MIN=15
# No internal `timeout` wrapper on apt full-upgrade — killing dpkg mid-postinst
# is worse than running long. The systemd unit owns the overall cap via
# TimeoutStartSec (see proxmox-monthly-update.service).

# Ensure the log is writable; if not, fall back to stderr only.
if ! { : >> "$LOG"; } 2>/dev/null; then
  echo "$(date -Is) [FATAL] cannot write log $LOG" >&2
  exit 1
fi

log()   { echo "$(date -Is) $*" | tee -a "$LOG"; }
ok()    { log "[OK]    $*"; }
warn()  { log "[WARN]  $*"; }
bad()   { log "[FAIL]  $*"; }
fatal() { bad "$1"; exit "${2:-1}"; }

# backup_activity <smbstatus-L-json> <quiet-minutes> <mount>...
# Ground truth for "is a Windows backup writing right now". An idle SMB SESSION is
# not activity: the PC keeps both shares mapped 24/7, and counting sessions blocked
# every run from 2026-09-06 to 2026-11-06. Activity = a file open over SMB, or any
# write under a backup mount within <quiet-minutes> (restic refreshes its repo lock
# every 5 min, so a running restic backup always shows a fresh write).
# Prints a reason. rc 0 = activity, 1 = quiet, 2 = could not verify (fail closed).
backup_activity() {
  local json="$1" quiet="$2" n d hit rc
  shift 2
  n=$(printf '%s' "$json" | jq -r '.open_files | if type == "object" then length else error("open_files missing") end' 2>/dev/null) \
    || { echo "cannot parse smbstatus JSON"; return 2; }
  case "$n" in ''|*[!0-9]*) echo "unexpected open_files count '$n'"; return 2 ;; esac
  if [ "$n" -gt 0 ]; then echo "$n file(s) open over SMB"; return 0; fi
  [ "$#" -gt 0 ] || { echo "no backup mounts given"; return 2; }
  for d in "$@"; do
    [ -d "$d" ] || { echo "$d is not a directory"; return 2; }
    hit=$(timeout 300 find "$d" -xdev -mmin "-$quiet" -print -quit 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || { echo "scan of $d failed (rc=$rc)"; return 2; }
    if [ -n "$hit" ]; then echo "$d written within the last ${quiet} min"; return 0; fi
  done
  echo "no files open over SMB and no backup writes in the last ${quiet} min"
  return 1
}

# Stamp the success marker atomically. A failure to stamp is only a warning here,
# but it is loud downstream: backup-health-check will report the updater as stale.
stamp_success() {
  if mkdir -p "$MARKER_DIR" && date +%s > "$MARKER.tmp" && mv -f "$MARKER.tmp" "$MARKER"; then
    ok "success marker stamped ($MARKER)"
  else
    warn "could not write success marker $MARKER - backup-health-check will report the updater as stale"
  fi
}

# record_running_guests <list-file> [boot-id-file]
# Writes "# boot_id <current boot>" then one "CT <id>" / "VM <id>" line per running
# guest, atomically (tmp + mv). The restore service uses the boot_id to prove a
# reboot happened (clocks can be off at boot).
# If an UNRESOLVED list from an earlier reboot is still there (a restore failed, so
# backup-health-check is alarming on it), its entries are carried over, so this run
# cannot silently drop guests that are still down and clear the alarm.
# Returns non-zero if either listing fails, so a half-known set is never written.
# pct list columns: VMID Status [Lock] Name (Status is always column 2);
# qm list columns: VMID NAME STATUS ... (Status is column 3).
record_running_guests() {
  local f="$1" bidf="${2:-/proc/sys/kernel/random/boot_id}" cts vms bid
  cts=$(pct list) || return 1
  vms=$(qm list) || return 1
  bid=$(cat "$bidf" 2>/dev/null) || return 1
  [[ "$bid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  mkdir -p "$(dirname "$f")" || return 1
  {
    echo "# boot_id $bid"
    {
      awk 'NR > 1 && $2 == "running" { print "CT", $1 }' <<<"$cts"
      awk 'NR > 1 && $3 == "running" { print "VM", $1 }' <<<"$vms"
      if [ -e "$f" ]; then
        grep -v '^# boot_id ' "$f"
        [ $? -le 1 ]   # 1 = no entries (fine); 2 = read error (fail the record)
      fi
    } | sort -u
  } > "$f.tmp" || return 1
  mv -f "$f.tmp" "$f"
}

# --- Lock: prevent concurrent runs. flock releases on FD close at script exit. ---
exec 200>"$LOCKFILE" || fatal "cannot open lockfile $LOCKFILE"
if ! flock -n 200; then
  fatal "another instance is already running (lockfile $LOCKFILE held)"
fi
echo $$ >&200   # write our PID into the locked FD for diagnostics

log "===================================================="
log "Proxmox auto-update START (dry-run=$DRY_RUN, snapshot=$SNAPSHOT_NAME)"
log "===================================================="

# ============================================================================
# Phase 1: pre-flight
# ============================================================================
log "Phase 1: pre-flight checks"

# /boot space — kernel packages can easily eat 200MB each
boot_avail_mb=$(df -BM --output=avail /boot 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -z "${boot_avail_mb:-}" ] || [ "$boot_avail_mb" -lt "$MIN_BOOT_MB" ]; then
  fatal "/boot has only ${boot_avail_mb:-?}MB free (need ${MIN_BOOT_MB}MB) — clean old kernels first"
fi
ok "/boot has ${boot_avail_mb}MB free"

# /var space — apt download cache + log writes
var_avail_gb=$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -z "${var_avail_gb:-}" ] || [ "$var_avail_gb" -lt "$MIN_VAR_GB" ]; then
  fatal "/var has only ${var_avail_gb:-?}GB free (need ${MIN_VAR_GB}GB)"
fi
ok "/var has ${var_avail_gb}GB free"

# Backup health — refuse to upgrade if the backup system is degraded
if [ -x "$HEALTH_CHECK" ]; then
  # Skip ITS auto-update check: a failed previous run would otherwise make the
  # health check fail, which would block this run forever.
  if ! BHC_SKIP_UPDATER_CHECK=1 "$HEALTH_CHECK" >/dev/null 2>&1; then
    fatal "backup-health-check failed — refusing to upgrade with broken backup state (see /var/log/backup-health-check.log)"
  fi
  ok "backup health check passed"
else
  warn "$HEALTH_CHECK not found or not executable — skipping backup health gate"
fi

# In-flight Proxmox backup (vzdump)? vzdump is a Perl script
# (/usr/bin/vzdump); pgrep-on-argv is fragile across PVE versions. Proxmox
# uses /var/run/vzdump.lock as a flock-protected file — the file is created
# once and PERSISTS forever; in-use status is determined by whether flock
# can acquire it exclusively. A successful flock means no vzdump in flight.
if [ -f /var/run/vzdump.lock ] && ! flock -n /var/run/vzdump.lock -c true 2>/dev/null; then
  fatal "vzdump lock is held — backup in progress"
fi
ok "no vzdump in flight"

# Windows backup in flight? (restic / Veeam over SMB to /mnt/backup-*). See
# backup_activity for why idle sessions don't count. Called twice: here, and again
# right before apt (a backup could start while the snapshots run). Each mount must
# be the REAL ext4 disk: an absent OWC drive leaves a bare directory behind, which
# would otherwise scan as "quiet" (the health check catches that too, but it is
# skipped with only a warning if missing). smbstatus rc is captured separately so
# a smbstatus failure fails CLOSED.
check_backup_quiet() {
  local d fstype smb_json smb_rc activity activity_rc
  for d in "${BACKUP_MOUNTS[@]}"; do
    timeout 60 ls "$d" >/dev/null 2>&1   # trigger x-systemd.automount
    fstype=$(findmnt -nro FSTYPE -t ext4 --mountpoint "$d" 2>/dev/null | head -1)
    [ "$fstype" = "ext4" ] || fatal "$d is not a mounted ext4 backup disk — cannot verify backup activity, refusing to upgrade"
  done
  smb_json=$(smbstatus -L --json 2>/dev/null)
  smb_rc=$?
  if [ "$smb_rc" -ne 0 ]; then
    fatal "smbstatus failed (rc=$smb_rc) — cannot verify SMB state, refusing to upgrade"
  fi
  activity=$(backup_activity "$smb_json" "$BACKUP_QUIET_MIN" "${BACKUP_MOUNTS[@]}")
  activity_rc=$?
  case "$activity_rc" in
    0) fatal "Windows backup in flight ($activity) — deferring" ;;
    1) ok "$activity" ;;
    *) fatal "cannot verify backup activity ($activity) — refusing to upgrade" ;;
  esac
}
check_backup_quiet

# Any in-progress Proxmox cluster task (migrate, restore, etc.)?
# Capture rc — pvesh failure shouldn't pass as "no tasks running".
cluster_tasks=$(pvesh get /cluster/tasks --output-format json 2>/dev/null)
pvesh_rc=$?
if [ "$pvesh_rc" -ne 0 ]; then
  fatal "pvesh failed (rc=$pvesh_rc) — cannot verify cluster task state, refusing to upgrade"
fi
if printf '%s' "$cluster_tasks" | grep -q '"status":"running"'; then
  fatal "an in-progress Proxmox task is running — refusing to upgrade"
fi
ok "no in-progress Proxmox cluster tasks"

# ============================================================================
# Dry-run exit: show what would be upgraded, no changes.
# ============================================================================
if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN: apt update + list --upgradable, no changes will be applied"
  apt update 2>&1 | tail -8 | tee -a "$LOG"
  log "DRY-RUN: packages that would be upgraded:"
  apt list --upgradable 2>/dev/null | tail -n +2 | tee -a "$LOG"
  log "DRY-RUN complete — exit 0"
  exit 0
fi

# ============================================================================
# Phase 2: snapshots
# ============================================================================
log "Phase 2: snapshots ($SNAPSHOT_NAME)"

if ! mkdir -p "$PREUPGRADE_DIR"; then
  fatal "could not create $PREUPGRADE_DIR — host filesystem may be unwritable"
fi
for src in /etc/pve /etc/network/interfaces /etc/samba/smb.conf /etc/default/grub /etc/nftables.d /etc/apt/sources.list.d; do
  if [ -e "$src" ]; then
    cp -a "$src" "$PREUPGRADE_DIR/" 2>>"$LOG" || warn "could not back up $src"
  fi
done
ok "/etc files backed up to $PREUPGRADE_DIR"

snap_failures=0

# Enumerate guests up front. If `pct list` or `qm list` fails (e.g., pmxcfs not
# mounted, auth broken), capture rc separately so we don't silently "snapshot
# zero guests" and proceed straight into apt full-upgrade. Fail closed.
pct_list_raw=$(pct list 2>/dev/null)
pct_list_rc=$?
if [ "$pct_list_rc" -ne 0 ]; then
  fatal "pct list failed (rc=$pct_list_rc) — cannot enumerate containers, refusing to upgrade"
fi
qm_list_raw=$(qm list 2>/dev/null)
qm_list_rc=$?
if [ "$qm_list_rc" -ne 0 ]; then
  fatal "qm list failed (rc=$qm_list_rc) — cannot enumerate VMs, refusing to upgrade"
fi

# Snapshot all CTs (running OR stopped — both can break from an LXC version bump)
while IFS= read -r ctid; do
  [ -z "$ctid" ] && continue
  log "  snapshotting CT $ctid as $SNAPSHOT_NAME"
  if ! pct snapshot "$ctid" "$SNAPSHOT_NAME" --description "Auto-update $DATE_TAG" >>"$LOG" 2>&1; then
    warn "CT $ctid snapshot failed (continuing)"
    snap_failures=$((snap_failures + 1))
  fi
done < <(printf '%s\n' "$pct_list_raw" | awk 'NR>1 {print $1}')

# Snapshot non-template VMs
while IFS= read -r vmid; do
  [ -z "$vmid" ] && continue
  if qm config "$vmid" 2>/dev/null | grep -qE '^template:[[:space:]]*1'; then
    log "  skipping VM $vmid (template)"
    continue
  fi
  log "  snapshotting VM $vmid as $SNAPSHOT_NAME"
  if ! qm snapshot "$vmid" "$SNAPSHOT_NAME" --description "Auto-update $DATE_TAG" >>"$LOG" 2>&1; then
    warn "VM $vmid snapshot failed (continuing)"
    snap_failures=$((snap_failures + 1))
  fi
done < <(printf '%s\n' "$qm_list_raw" | awk 'NR>1 {print $1}')

if [ "$snap_failures" -gt 0 ]; then
  fatal "${snap_failures} snapshot(s) failed — refusing to upgrade without rollback path"
fi
ok "all snapshots created"

# ============================================================================
# Phase 3: apt full-upgrade
# ============================================================================
log "Phase 3: apt update + full-upgrade"

# Re-check right before the first package change: the snapshots take minutes, and
# a backup that started meanwhile would be cut off by a samba restart or reboot.
# A residual window remains (a backup starting DURING apt); Veeam (04:30) and
# restic (20:00) never start near the 02:30 slot, and both retry the next night.
check_backup_quiet

apt update 2>&1 | tee -a "$LOG"
apt_update_rc=${PIPESTATUS[0]}
if [ "$apt_update_rc" -ne 0 ]; then
  fatal "apt update failed (rc=$apt_update_rc) — aborting before any package change" 2
fi

apt_list_raw=$(apt list --upgradable 2>/dev/null)
apt_list_rc=$?
if [ "$apt_list_rc" -ne 0 ]; then
  fatal "apt list --upgradable failed (rc=$apt_list_rc) — apt state is inconsistent" 2
fi
upgradable=$(printf '%s\n' "$apt_list_raw" | tail -n +2)
if [ -z "$upgradable" ]; then
  ok "nothing to upgrade — exiting"
  stamp_success
  log "Auto-update COMPLETE (no-op)"
  exit 0
fi
upgrade_count=$(printf '%s\n' "$upgradable" | wc -l)
log "  $upgrade_count package(s) to upgrade"
printf '%s\n' "$upgradable" >>"$LOG"

# force-confold + force-confdef preserves our customized /etc files (sshd_config,
# smb.conf, grub) without prompting; maintainer-default changes are only accepted
# where we don't have our own version of the file.
#
# NO `timeout` wrapper here: killing apt mid-dpkg can leave the host in a state
# requiring manual `dpkg --configure -a` recovery. The systemd unit owns the
# overall timeout via TimeoutStartSec — see proxmox-monthly-update.service.
env DEBIAN_FRONTEND=noninteractive \
    apt full-upgrade -y \
      -o Dpkg::Options::=--force-confold \
      -o Dpkg::Options::=--force-confdef \
    2>&1 | tee -a "$LOG"
apt_rc=${PIPESTATUS[0]}
if [ "$apt_rc" -ne 0 ]; then
  fatal "apt full-upgrade exited $apt_rc — snapshots intact, manual recovery needed (see $LOG)" 2
fi
ok "apt full-upgrade complete"

# ============================================================================
# Phase 4: reboot decision
#
# Proxmox VE does NOT install update-notifier-common (no /var/run/reboot-required)
# and does not ship needrestart by default — so we cannot rely on either of the
# usual Debian indicators. Instead, compare the running kernel against the latest
# installed proxmox-kernel-*-pve-signed package: any mismatch means a new kernel
# was unpacked and we need to reboot into it.
#
# Note: libc6 / openssl / systemd upgrades usually only need a service restart
# (dpkg trigger handles that during the apt run). They very rarely require a
# full reboot — if one ever does, the running-vs-installed kernel check won't
# catch it, but that's an edge case worth living with vs. always-rebooting.
# ============================================================================
log "Phase 4: reboot decision"

reboot_scheduled=0
running_kernel=$(uname -r)
# Pick the highest-versioned signed proxmox kernel currently installed.
# Filter to actually-installed (status `ii`) — dpkg-query can list removed
# packages whose records are still in the database otherwise.
installed_kernel=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null \
  | awk '$1 == "ii" {print $2}' \
  | sed -e 's/^proxmox-kernel-//' -e 's/-signed$//' \
  | sort -V | tail -1)

if [ -z "$installed_kernel" ]; then
  warn "could not determine installed proxmox kernel — skipping reboot decision (manual check recommended)"
elif [ "$running_kernel" != "$installed_kernel" ]; then
  log "  running kernel $running_kernel != latest installed $installed_kernel — reboot required"
  # Record what is running so proxmox-guest-restore.service can bring it back.
  # Failing here is fatal BEFORE the reboot is scheduled: the unit fails, the
  # marker is not stamped, and backup-health-check check 6 alarms, instead of
  # the onboot=0 lab guests silently staying down after the reboot.
  if record_running_guests "$RESTORE_LIST"; then
    ok "recorded $(grep -vc '^# boot_id ' "$RESTORE_LIST") guest(s) for post-reboot restore ($RESTORE_LIST)"
  else
    fatal "could not record running guests to $RESTORE_LIST — reboot NOT scheduled; reboot by hand and restart the guests that were running" 2
  fi
  sync   # flush log + dpkg state to disk before kernel hands off
  # +1 minute gives systemd time to ack and gives any open shell a chance to bail.
  # PIPESTATUS check so a failed shutdown doesn't get masked by tee's 0 exit and
  # then `reboot_scheduled=1` would lie about a reboot that never happened.
  shutdown -r +1 "Proxmox auto-update — new kernel $installed_kernel, rebooting" 2>&1 | tee -a "$LOG"
  shutdown_rc=${PIPESTATUS[0]}
  if [ "$shutdown_rc" -ne 0 ]; then
    fatal "shutdown -r +1 failed (rc=$shutdown_rc) — apt full-upgrade completed but reboot did not schedule; manual reboot required" 2
  fi
  reboot_scheduled=1
  log "Reboot scheduled in +1m; backup-health-check.timer @09:00 will validate"
else
  ok "running kernel matches latest installed ($running_kernel) — no reboot required"
  # Other package updates handle their own service restarts via dpkg triggers.
fi

# ============================================================================
# Phase 5: cleanup old auto_update_* snapshots (retention)
# Only runs if we did NOT just schedule a reboot — let the post-reboot health
# check confirm the new state is good before we delete safety snapshots. Also
# avoids racing the in-flight shutdown-r-+1 against a long delsnapshot loop.
# ============================================================================
if [ "$reboot_scheduled" = 0 ]; then
  log "Phase 5: cleanup snapshots older than ${SNAPSHOT_RETENTION_DAYS} days"
  cutoff_ym=$(date -d "${SNAPSHOT_RETENTION_DAYS} days ago" +%Y_%m)
  pruned=0

  # CTs
  while IFS= read -r ctid; do
    [ -z "$ctid" ] && continue
    while IFS= read -r snap; do
      [ -z "$snap" ] && continue
      snap_ym=${snap#auto_update_}
      # Lexicographic compare works for YYYY_MM
      if [ "$snap_ym" \< "$cutoff_ym" ]; then
        log "  pruning CT $ctid snapshot $snap (older than ${SNAPSHOT_RETENTION_DAYS}d)"
        pct delsnapshot "$ctid" "$snap" >>"$LOG" 2>&1 && pruned=$((pruned + 1)) \
          || warn "CT $ctid delsnapshot $snap failed"
      fi
    done < <(pct listsnapshot "$ctid" 2>/dev/null | awk '/auto_update_/ {print $2}')
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

  # VMs
  while IFS= read -r vmid; do
    [ -z "$vmid" ] && continue
    while IFS= read -r snap; do
      [ -z "$snap" ] && continue
      snap_ym=${snap#auto_update_}
      if [ "$snap_ym" \< "$cutoff_ym" ]; then
        log "  pruning VM $vmid snapshot $snap (older than ${SNAPSHOT_RETENTION_DAYS}d)"
        qm delsnapshot "$vmid" "$snap" >>"$LOG" 2>&1 && pruned=$((pruned + 1)) \
          || warn "VM $vmid delsnapshot $snap failed"
      fi
    done < <(qm listsnapshot "$vmid" 2>/dev/null | awk '/auto_update_/ {print $2}')
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

  log "  pruned $pruned old snapshot(s)"
fi

stamp_success
log "===================================================="
if [ "$reboot_scheduled" = 1 ]; then
  log "Proxmox auto-update END — reboot pending"
else
  log "Proxmox auto-update END — no reboot"
fi
log "===================================================="
exit 0
