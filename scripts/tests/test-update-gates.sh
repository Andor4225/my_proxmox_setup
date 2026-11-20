#!/bin/bash
# test-update-gates.sh - tests for the auto-updater's backup-activity gate and
# snapshot naming/retention (proxmox-monthly-update.sh: backup_activity,
# snapshot_tag, snap_expired) and the health check's updater
# alarm (backup-health-check.sh: check_updater + the whole script end to end).
#
# The REAL functions are extracted from the scripts (not copies), and every path
# is a mktemp sandbox: nothing live is read or written except read-only probes
# (mount checks, systemctl show, journalctl) made by the end-to-end run.
# Run on the Proxmox host (needs jq):  bash test-update-gates.sh [scripts-dir]
set -uo pipefail
export LC_ALL=C

DIR=${1:-$(cd "$(dirname "$0")/.." && pwd)}
UPD="$DIR/proxmox-monthly-update.sh"
BHC="$DIR/backup-health-check.sh"
for f in "$UPD" "$BHC"; do [ -r "$f" ] || { echo "missing $f"; exit 2; }; done
command -v jq >/dev/null || { echo "jq required"; exit 2; }

SB=$(mktemp -d /tmp/upd-gate-test.XXXXXX) || exit 2
case "$SB" in /tmp/upd-gate-test.*) ;; *) echo "bad sandbox path"; exit 2 ;; esac
trap 'rm -rf -- "$SB"' EXIT

PASS=0; FAILS=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; }
expect() { # expect <label> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}

extract() { # extract <file> <function-name>
  awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"
}
for fn in backup_activity; do
  src=$(extract "$UPD" "$fn"); [ -n "$src" ] || { echo "cannot extract $fn"; exit 2; }; eval "$src"
done
src=$(extract "$BHC" check_updater); [ -n "$src" ] || { echo "cannot extract check_updater"; exit 2; }; eval "$src"

# ---------------- backup_activity ----------------
A="$SB/files"; B="$SB/images"; mkdir -p "$A/restic/locks" "$B/Window-Backup_2"
touch -d '2 hours ago' "$A/restic/config" "$B/Window-Backup_2/x.vbk"
touch -d '2 hours ago' "$A/restic/locks" "$A/restic" "$A" "$B/Window-Backup_2" "$B"
IDLE='{"timestamp":"t","version":"4.22.8","smb_conf":"/etc/samba/smb.conf","open_files":{}}'
OPEN='{"open_files":{"/mnt/backup-images/Window-Backup_2/x.vbk":{"service_path":"/mnt/backup-images","filename":"Window-Backup_2/x.vbk","opens":{"1":{}}}}}'

ba() { backup_activity "$@" >/dev/null; echo $?; }
expect "idle session, no open files, old mtimes -> quiet (1)"      1 "$(ba "$IDLE" 15 "$A" "$B")"
expect "one file open over SMB -> activity (0)"                     0 "$(ba "$OPEN" 15 "$A" "$B")"
touch "$A/restic/locks/abc123"
expect "fresh restic lock file, nothing open -> activity (0)"       0 "$(ba "$IDLE" 15 "$A" "$B")"
touch -d '2 hours ago' "$A/restic/locks/abc123" "$A/restic/locks"
expect "same lock aged past the quiet window -> quiet (1)"          1 "$(ba "$IDLE" 15 "$A" "$B")"
touch "$B/Window-Backup_2/x.vbk"
expect "write in the SECOND mount only -> activity (0)"             0 "$(ba "$IDLE" 15 "$A" "$B")"
touch -d '2 hours ago' "$B/Window-Backup_2/x.vbk"
expect "open_files key missing -> cannot verify (2), not quiet"     2 "$(ba '{"version":"x"}' 15 "$A" "$B")"
expect "open_files null -> cannot verify (2)"                       2 "$(ba '{"open_files":null}' 15 "$A" "$B")"
expect "open_files is a list -> cannot verify (2)"                  2 "$(ba '{"open_files":[]}' 15 "$A" "$B")"
expect "garbage JSON -> cannot verify (2)"                          2 "$(ba 'No locked files' 15 "$A" "$B")"
expect "empty smbstatus output -> cannot verify (2)"                2 "$(ba '' 15 "$A" "$B")"
expect "mount missing -> cannot verify (2)"                         2 "$(ba "$IDLE" 15 "$A" "$SB/nope")"
expect "no mounts given -> cannot verify (2)"                       2 "$(ba "$IDLE" 15)"
chmod 000 "$A/restic"
if [ "$(id -u)" -ne 0 ]; then
  expect "unreadable subtree (find rc!=0) -> cannot verify (2)"     2 "$(ba "$IDLE" 15 "$A" "$B")"
else
  echo "SKIP  unreadable-subtree case (root bypasses permissions)"
fi
chmod 755 "$A/restic"

# ---------------- snapshot naming + retention ----------------
src=$(extract "$UPD" snap_expired); [ -n "$src" ] || { echo "cannot extract snap_expired"; exit 2; }; eval "$src"
src=$(grep -m1 '^snapshot_tag() {.*}$' "$UPD"); [ -n "$src" ] || { echo "cannot extract snapshot_tag"; exit 2; }; eval "$src"
t1=$(snapshot_tag "2026-11-10 10:22"); t2=$(snapshot_tag "2026-11-20 02:38")
expect "tag format is YYYY_MM_DD_HHMMSS"                             2026_11_20_023800 "$t2"
if [ "$t1" != "$t2" ]; then pass "two runs in one month get different names (the 2026-11-20 collision)"; else fail "same-month runs collide: $t1"; fi
if [ "$(snapshot_tag '2026-11-20 02:38')" != "$(snapshot_tag '2026-11-20 09:15')" ]; then pass "same-day rerun gets a different name"; else fail "same-day rerun collides"; fi
if [ "$(snapshot_tag '2026-11-20 02:38:05')" != "$(snapshot_tag '2026-11-20 02:38:50')" ]; then pass "same-minute rerun gets a different name"; else fail "same-minute rerun collides"; fi
n="auto_update_$t2"
if [ ${#n} -le 40 ] && [[ $n =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then pass "name is a valid Proxmox snapshot id ($n)"; else fail "invalid snapshot id: $n"; fi
se() { snap_expired "$1" "$2"; echo $?; }
expect "new name before cutoff -> expired"                          0 "$(se auto_update_2026_09_20_023800 2026_09_21)"
expect "new name on the cutoff day -> kept"                         1 "$(se auto_update_2026_09_21_023800 2026_09_21)"
expect "new name after cutoff -> kept"                              1 "$(se auto_update_2026_11_20_023800 2026_09_21)"
expect "legacy month name, earlier month -> expired"                0 "$(se auto_update_2026_08 2026_09_21)"
expect "legacy month name, cutoff month -> kept (old month rule)"   1 "$(se auto_update_2026_09 2026_09_21)"
expect "legacy month name, later month -> kept"                     1 "$(se auto_update_2026_11 2026_09_21)"
expect "manual auto_update_foo -> never pruned"                     1 "$(se auto_update_before_upgrade 2099_01_01)"
expect "other-prefix name -> never pruned"                          1 "$(se pre_kernel_2020_01_01_000000 2099_01_01)"
expect "bare tag, no auto_update_ prefix -> never pruned"           1 "$(se 2020_01_01_000000 2099_01_01)"
expect "near-miss format (no minutes) -> never pruned"              1 "$(se auto_update_2020_01_01 2099_01_01)"
expect "near-miss format (HHMM, no seconds) -> never pruned"        1 "$(se auto_update_2020_01_01_0000 2099_01_01)"
expect "suffixed manual keep copy -> never pruned (end anchor)"     1 "$(se auto_update_2020_01_01_000000_keep 2099_01_01)"
expect "letter-prefixed tag -> never pruned"                        1 "$(se auto_update_x2020_01_01_000000 2099_01_01)"
expect "digit-prefixed tag -> never pruned (start anchor)"          1 "$(se auto_update_1_2020_01_01_000000 2099_01_01)"
expect "suffixed legacy name -> never pruned"                       1 "$(se auto_update_2020_01_keep 2099_01_01)"
expect "empty cutoff (date failed) -> prunes nothing"               1 "$(se auto_update_2020_01_01_000000 '')"
expect "malformed cutoff -> prunes nothing"                         1 "$(se auto_update_2020_01_01_000000 2099_01)"
expect "cutoff month 00 (not a date) -> prunes nothing"             1 "$(se auto_update_2026_01_01_000000 2099_00_00)"
expect "cutoff Feb 31 (not a date) -> prunes nothing"               1 "$(se auto_update_2026_01_01_000000 2026_02_31)"
expect "real calendar cutoff still prunes (control)"                0 "$(se auto_update_2026_01_01_000000 2026_02_28)"

# ---------------- check_backup_quiet (mount verification + live gate) ----------------
src=$(extract "$UPD" check_backup_quiet); [ -n "$src" ] || { echo "cannot extract check_backup_quiet"; exit 2; }; eval "$src"
cbq() { # run in a subshell: fatal exits it. Prints the decisive log line.
  (
    log() { echo "$*"; }; ok() { log "[OK] $*"; }; bad() { log "[FAIL] $*"; }
    fatal() { bad "$1"; exit 1; }
    BACKUP_QUIET_MIN=15; BACKUP_MOUNTS=("$@")
    check_backup_quiet
  ) 2>&1 | tail -1
}
out=$(cbq "$A" "$B")
case "$out" in *"not a mounted ext4"*) pass "bare (unmounted) directories are refused, not scanned as quiet";; *) fail "bare dirs: $out";; esac
if findmnt -nro FSTYPE -t ext4 --mountpoint /mnt/backup-files >/dev/null 2>&1; then
  out=$(cbq /mnt/backup-files /mnt/backup-images)
  case "$out" in
    *"[OK] no files open over SMB"*|*"in flight"*) pass "live mounts pass the mount check and reach the activity verdict ($out)";;
    *) fail "live mounts: $out";;
  esac
else
  echo "SKIP  live-mount case (not on the Proxmox host)"
fi

# ---------------- check_updater ----------------
CU_LOG="$SB/cu.log"
log()  { echo "$*" >> "$CU_LOG"; }
ok()   { log "[OK]   $*"; }
warn() { log "[WARN] $*"; WARN=$((WARN + 1)); }
bad()  { log "[FAIL] $*"; }
NOW=$(date +%s)
M="$SB/last-success"; ULOG="$SB/upd.log"
printf '%s\n' "2026-11-06T02:34:33-06:00 [FAIL]  1 active SMB client(s) — backup may be in flight" > "$ULOG"

cu() { # cu <result> <exit-epoch>  -> prints "<warns>|<last line>"
  WARN=0; : > "$CU_LOG"
  check_updater "$M" "$1" "$2" "$ULOG" 20
  echo "$WARN|$(tail -1 "$CU_LOG")"
}
rm -f "$M"
r=$(cu success ""); expect "marker missing -> warn" 1 "${r%%|*}"
case "$r" in *"missing"*) pass "missing-marker text names the cause";; *) fail "missing-marker text: $r";; esac
echo $((NOW - 86400)) > "$M"
r=$(cu success ""); expect "fresh marker (1d), unit success -> no warn" 0 "${r%%|*}"
echo $((NOW - 25 * 86400)) > "$M"
r=$(cu success ""); expect "stale marker (25d) -> warn" 1 "${r%%|*}"
echo $((NOW - 19 * 86400)) > "$M"
r=$(cu success ""); expect "19d (inside the 20d limit) -> no warn" 0 "${r%%|*}"
echo $((NOW + 3600)) > "$M"
r=$(cu success ""); expect "future marker -> warn" 1 "${r%%|*}"
echo "not-a-number" > "$M"
r=$(cu success ""); expect "malformed marker -> warn" 1 "${r%%|*}"
: > "$M"
r=$(cu success ""); expect "empty marker -> warn" 1 "${r%%|*}"
echo "12a34" > "$M"
r=$(cu success ""); expect "partly numeric marker -> warn (anchored regex)" 1 "${r%%|*}"
printf '%s\n%s\n' "$((NOW - 86400))" "456" > "$M"
r=$(cu success ""); expect "two-line marker -> warn (lines not merged)" 1 "${r%%|*}"
printf '  %s\n' "$((NOW - 86400))" > "$M"
r=$(cu success ""); expect "marker with leading whitespace -> warn" 1 "${r%%|*}"
printf '%s' "$((NOW - 86400))" > "$M"
r=$(cu success ""); expect "marker without trailing newline -> accepted" 0 "${r%%|*}"
printf '%s\n' "$((NOW - 86400))1234567890123456789012345" > "$M"
r=$(cu success ""); expect "over-long marker (truncated read) -> warn, not a bogus epoch" 1 "${r%%|*}"
if command -v python3 >/dev/null; then
  # epoch + 2^64: bash arithmetic wraps it back to a FRESH epoch, so only the
  # 12-digit cap stops it reading as "updated 1d ago".
  python3 -c "print($NOW - 86400 + 2**64)" > "$M"
  r=$(cu success ""); expect "epoch+2^64 (wraps to fresh in bash) -> warn via length cap" 1 "${r%%|*}"
else
  echo "SKIP  overflow-wrap case (python3 missing)"
fi
echo $((NOW - 86400)) > "$M"
r=$(cu exit-code $((NOW - 3600))); expect "unit failed AFTER the last success -> warn" 1 "${r%%|*}"
WARN=0; : > "$CU_LOG"; check_updater "$M" exit-code $((NOW - 3600)) "$ULOG" 20
if grep -q 'active SMB client' "$CU_LOG"; then pass "failed-run warning quotes the updater's last [FAIL] line"; else fail "failed-run warning lacks the [FAIL] reason"; fi
r=$(cu exit-code $((NOW - 2 * 86400))); expect "unit failure superseded by a later success -> no warn" 0 "${r%%|*}"
r=$(cu exit-code ""); expect "unit failed, exit time unknown -> warn (unknown is not superseded)" 1 "${r%%|*}"
r=$(cu "" ""); expect "systemctl gave no result -> marker still decides (no warn)" 0 "${r%%|*}"
rm -f "$M"
r=$(cu exit-code $((NOW - 3600))); expect "unit failed AND no marker -> two warnings" 2 "${r%%|*}"

# ---------------- backup-health-check end to end ----------------
# The real script with LOG + marker redirected to the sandbox. Mount, restic and
# Veeam checks read the live (read-only) state, so only check 6 is asserted.
E2E_LOG="$SB/bhc.log"
echo $((NOW - 3 * 86400)) > "$M"
BHC_LOG="$E2E_LOG" BHC_UPDATE_MARKER="$M" bash "$BHC" >/dev/null 2>&1
if grep -q 'last successful auto-update 3d ago' "$E2E_LOG"; then pass "e2e: fresh marker reported OK"; else fail "e2e: no OK line for a fresh marker"; fi
rm -f "$M"; : > "$E2E_LOG"
BHC_LOG="$E2E_LOG" BHC_UPDATE_MARKER="$M" bash "$BHC" >/dev/null 2>&1; rc=$?
if grep -q '\[WARN\] no successful auto-update recorded' "$E2E_LOG"; then pass "e2e: missing marker -> [WARN] line (the format OpenClaw forwards)"; else fail "e2e: missing marker gave no [WARN]"; fi
if [ "$rc" -ge 1 ]; then pass "e2e: missing marker -> non-zero exit ($rc), so OpenClaw alerts"; else fail "e2e: exit 0 despite missing marker"; fi
: > "$E2E_LOG"
BHC_SKIP_UPDATER_CHECK=1 BHC_LOG="$E2E_LOG" BHC_UPDATE_MARKER="$M" bash "$BHC" >/dev/null 2>&1
if grep -q 'skipping auto-update check' "$E2E_LOG" && ! grep -q 'auto-update recorded' "$E2E_LOG"; then
  pass "e2e: BHC_SKIP_UPDATER_CHECK=1 skips check 6 (no updater/health-check deadlock)"
else fail "e2e: skip flag did not skip check 6"; fi
if [ -e "$M" ]; then fail "e2e: health check created the marker (must only ever read it)"; else pass "e2e: health check never writes the marker"; fi

echo "ran: $((PASS + FAILS))  failures: $FAILS"
[ "$FAILS" -eq 0 ]
