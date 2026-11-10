#!/bin/bash
# proxmox-guest-restore.sh — after a proxmox-monthly-update reboot, start the guests
# that were running before it. Run once at boot by proxmox-guest-restore.service,
# ordered after pve-guests.service (which starts the onboot=1 guests).
#
# Why: the lab guests (FAE CT 201-207, CTF CT 211-215, VM 110) are onboot=0 on
# purpose, so a power cut leaves the deliberately vulnerable CTF lab down. But an
# updater reboot is planned, so whatever was running should come back. Added
# 2026-11-10; before that the 13 lab guests had to be restarted by hand.
#
# Input: $LIST, written atomically by proxmox-monthly-update.sh just before it
# schedules the reboot. Line 1 is "# boot_id <id of the boot that wrote it>", then
# one "CT <id>" or "VM <id>" per line.
#
# Reboot identity uses the kernel boot_id, not clocks (the RTC can be off at boot,
# before chrony syncs). Fail-closed rules — every unknown keeps the list and exits 1,
# and the list left behind is what backup-health-check check 6 alarms on:
#   - missing/malformed boot_id header -> refuse
#   - boot_id equals the current boot (no reboot happened yet) -> refuse
#   - list older than MAX_AGE_H (the updater's reboot was cancelled and this is an
#     unrelated later boot), or dated more than FUTURE_TOL_S ahead -> refuse
#   - malformed line, unknown guest, status timeout, failed start -> keep the list
#   - after all starts and a settle period, every listed guest is re-checked; only
#     if ALL are running is the list archived to $LIST.done
#
# Test seams: PGR_LIST, PGR_LOG, PGR_BOOT_ID, PGR_NOW, PGR_PCT, PGR_QM,
#             PGR_SETTLE_S, PGR_STATUS_TIMEOUT.
# Exit: 0 = nothing to do or all restored, 1 = refused or a guest is not running.

set -uo pipefail
export LC_ALL=C

LIST=${PGR_LIST:-/var/lib/proxmox-monthly-update/restore-guests}
LOG=${PGR_LOG:-/var/log/proxmox-monthly-update.log}
PCT=${PGR_PCT:-pct}
QM=${PGR_QM:-qm}
SETTLE_S=${PGR_SETTLE_S:-15}
STATUS_TIMEOUT=${PGR_STATUS_TIMEOUT:-30}
START_TIMEOUT=120
MAX_AGE_H=6
FUTURE_TOL_S=3600

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

log() { echo "$(date -Is) [guest-restore] $*" | tee -a "$LOG"; }
ok()  { log "[OK]    $*"; }
bad() { log "[FAIL]  $*"; }

# guest_status <CT|VM> <id> -> prints running|stopped|..., or NOTHING if the status
# command failed or timed out (even if it printed a status line before failing).
guest_status() {
  local tool out
  if [ "$1" = CT ]; then tool=$PCT; else tool=$QM; fi
  out=$(timeout "$STATUS_TIMEOUT" "$tool" status "$2" 2>/dev/null) || return 1
  awk '/^status:/ {print $2}' <<<"$out"
}

if [ ! -e "$LIST" ]; then
  log "no restore list ($LIST) — nothing to do"
  exit 0
fi

# Checksum of the list as read: if the updater rewrites it while we work, the new
# version is left pending instead of being archived unchecked.
list_sum=$(sha256sum < "$LIST" 2>/dev/null) || { bad "cannot read $LIST — not restoring; list kept"; exit 1; }
header=$(head -n 1 "$LIST" 2>/dev/null)
list_boot=${header#\# boot_id }
if [ "$list_boot" = "$header" ] || ! [[ "$list_boot" =~ $UUID_RE ]]; then
  bad "$LIST has no valid '# boot_id <uuid>' header — not restoring; list kept"
  exit 1
fi
cur_boot=${PGR_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}
if ! [[ "$cur_boot" =~ $UUID_RE ]]; then
  bad "cannot read the current boot_id — not restoring; list kept"
  exit 1
fi
if [ "$cur_boot" = "$list_boot" ]; then
  bad "$LIST was written during this boot (no reboot since) — not restoring; list kept"
  exit 1
fi

now=${PGR_NOW:-$(date +%s)}
mtime=$(stat -c %Y "$LIST" 2>/dev/null)
if ! [[ "$mtime" =~ ^[0-9]+$ ]] || ! [[ "$now" =~ ^[0-9]+$ ]]; then
  bad "cannot read the age of $LIST — not restoring; list kept"
  exit 1
fi
age_s=$(( now - mtime ))
if [ "$age_s" -gt $(( MAX_AGE_H * 3600 )) ]; then
  bad "$LIST is $(( age_s / 3600 ))h old (> ${MAX_AGE_H}h: the updater's reboot was likely cancelled) — not restoring; start guests by hand, then delete the list"
  exit 1
fi
if [ "$age_s" -lt $(( -FUTURE_TOL_S )) ]; then
  bad "$LIST is dated $(( -age_s / 60 )) min in the future (clock skew) — not restoring; list kept"
  exit 1
fi

log "restoring guests from $LIST"
failed=0 started=0 already=0
declare -a GUESTS=()
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^\#\ boot_id\  ]] && continue
  if ! [[ "$line" =~ ^(CT|VM)\ ([0-9]{3,9})$ ]]; then
    bad "malformed line in $LIST: '${line:0:60}'"
    failed=$((failed + 1)); continue
  fi
  kind=${BASH_REMATCH[1]} id=${BASH_REMATCH[2]}
  GUESTS+=("$kind $id")
  st=$(guest_status "$kind" "$id") || st=""
  case "$st" in
    running) already=$((already + 1)); ok "$kind $id already running" ;;
    stopped)
      if [ "$kind" = CT ]; then tool=$PCT; else tool=$QM; fi
      if timeout "$START_TIMEOUT" "$tool" start "$id" >>"$LOG" 2>&1; then
        started=$((started + 1)); ok "started $kind $id"
      else
        failed=$((failed + 1)); bad "could not start $kind $id"
      fi ;;
    *) failed=$((failed + 1)); bad "$kind $id: unknown guest, unreadable status or status timeout ('${st:-none}')" ;;
  esac
done < "$LIST"

# Re-verify: a start that returned 0 can still crash, or something else can stop it.
if [ "${#GUESTS[@]}" -gt 0 ]; then
  sleep "$SETTLE_S"
  for g in "${GUESTS[@]}"; do
    st=$(guest_status "${g% *}" "${g#* }") || st=""
    if [ "$st" != running ]; then
      failed=$((failed + 1)); bad "$g is not running after the settle period (status '${st:-none}')"
    fi
  done
fi

if [ "$failed" -gt 0 ]; then
  bad "$failed problem(s) restoring guests ($started started, $already already running) — list kept at $LIST"
  exit 1
fi
if [ "$(sha256sum < "$LIST" 2>/dev/null)" != "$list_sum" ]; then
  bad "$LIST changed while restoring (updater rewrote it?) — the new version is left pending; list kept"
  exit 1
fi
mv -f "$LIST" "$LIST.done" || { bad "restored all guests but could not archive $LIST"; exit 1; }
ok "all ${#GUESTS[@]} listed guest(s) running ($started started, $already already running); list archived to $LIST.done"
exit 0
