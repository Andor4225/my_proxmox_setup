#!/bin/bash
# test-guest-restore.sh - tests for the post-update guest restore:
#   proxmox-monthly-update.sh   record_running_guests (extracted, pct/qm stubbed)
#   proxmox-guest-restore.sh    the whole script, end to end, via its PGR_* seams
#   backup-health-check.sh      check_guest_restore (extracted) + end to end
# Every path is a mktemp sandbox and pct/qm are stubs: no real guest is started,
# stopped or listed, and no live file is written.
# Run on the Proxmox host:  bash test-guest-restore.sh [scripts-dir]
set -uo pipefail
export LC_ALL=C

DIR=${1:-$(cd "$(dirname "$0")/.." && pwd)}
UPD="$DIR/proxmox-monthly-update.sh"
PGR="$DIR/proxmox-guest-restore.sh"
BHC="$DIR/backup-health-check.sh"
for f in "$UPD" "$PGR" "$BHC"; do [ -r "$f" ] || { echo "missing $f"; exit 2; }; done

SB=$(mktemp -d /tmp/guest-restore-test.XXXXXX) || exit 2
case "$SB" in /tmp/guest-restore-test.*) ;; *) echo "bad sandbox path"; exit 2 ;; esac
trap 'rm -rf -- "$SB"' EXIT

PASS=0; FAILS=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
extract() { awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"; }

BOOT_OLD=11111111-2222-3333-4444-555555555555
BOOT_NEW=99999999-8888-7777-6666-555555555555

# ---------------- record_running_guests (updater) ----------------
src=$(extract "$UPD" record_running_guests); [ -n "$src" ] || { echo "cannot extract record_running_guests"; exit 2; }; eval "$src"
PCT_OUT='VMID       Status     Lock         Name
201        running                 lab1-router
202        stopped                 lab1-client
211        running    backup       ctf-web
300        running                 dfwagentops-web'
QM_OUT='      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 ubuntu-target        stopped    4096              32.00 0
       110 omarchy              running    8192              64.00 1234
       900 staging-template     stopped    2048              32.00 0'
PCT_RC=0; QM_RC=0
pct() { [ "$1" = list ] && { echo "$PCT_OUT"; return "$PCT_RC"; }; return 9; }
qm()  { [ "$1" = list ] && { echo "$QM_OUT"; return "$QM_RC"; }; return 9; }
BIDF="$SB/boot_id"; echo "$BOOT_OLD" > "$BIDF"

L="$SB/lib/restore-guests"
record_running_guests "$L" "$BIDF"; rc=$?
expect "record: no previous list -> returns 0" 0 "$rc"
expect "record: boot_id header first" "# boot_id $BOOT_OLD" "$(head -n1 "$L")"
expect "record: running CTs (lock column empty or set) and VMs, nothing stopped" \
  "CT 201|CT 211|CT 300|VM 110" "$(tail -n +2 "$L" | paste -sd'|')"
[ -e "$L.tmp" ] && fail "record: left a .tmp file" || pass "record: no .tmp left behind"

printf '# boot_id %s\nCT 202\nCT 201\n' "$BOOT_NEW" > "$L"   # unresolved list from an earlier reboot
record_running_guests "$L" "$BIDF"; rc=$?
expect "record: merge with an unresolved list -> returns 0" 0 "$rc"
expect "record: still-down CT 202 carried over, no duplicates, one header" \
  "# boot_id $BOOT_OLD|CT 201|CT 202|CT 211|CT 300|VM 110" "$(paste -sd'|' "$L")"
printf '# boot_id %s\n' "$BOOT_NEW" > "$L"                     # header-only previous list
record_running_guests "$L" "$BIDF"; rc=$?
expect "record: header-only previous list -> returns 0 (grep no-match is not an error)" 0 "$rc"

echo "CT 999" > "$L"
PCT_RC=1; record_running_guests "$L" "$BIDF"; rc=$?; PCT_RC=0
[ "$rc" -ne 0 ] && pass "record: pct list failure -> non-zero" || fail "record: pct list failure returned 0"
expect "record: failed listing leaves the previous file untouched" "CT 999" "$(cat "$L")"
QM_RC=1; record_running_guests "$L" "$BIDF"; rc=$?; QM_RC=0
[ "$rc" -ne 0 ] && pass "record: qm list failure -> non-zero" || fail "record: qm list failure returned 0"
record_running_guests "$L" "$SB/no-such-boot-id"; rc=$?
[ "$rc" -ne 0 ] && pass "record: unreadable boot_id -> non-zero" || fail "record: unreadable boot_id returned 0"
printf '%s\n' '------------------------------------' > "$SB/bad-boot-id"
record_running_guests "$L" "$SB/bad-boot-id"; rc=$?
[ "$rc" -ne 0 ] && pass "record: non-UUID boot_id -> non-zero" || fail "record: non-UUID boot_id returned 0"
unset -f pct qm

# Structural: the record call sits before `shutdown -r` and a failure is fatal.
rec_ln=$(grep -n 'if record_running_guests "\$RESTORE_LIST"' "$UPD" | head -1 | cut -d: -f1)
shut_ln=$(grep -n '^ *shutdown -r ' "$UPD" | head -1 | cut -d: -f1)
if [ -n "$rec_ln" ] && [ -n "$shut_ln" ] && [ "$rec_ln" -lt "$shut_ln" ]; then
  pass "updater records guests before scheduling the reboot"
else fail "record call missing or after shutdown -r (rec=$rec_ln shut=$shut_ln)"; fi
if sed -n "${rec_ln:-1},${shut_ln:-1}p" "$UPD" | grep -q 'fatal "could not record running guests'; then
  pass "updater: record failure is fatal before the reboot"
else fail "updater: record failure is not fatal"; fi

# ---------------- proxmox-guest-restore.sh (end to end) ----------------
ST="$SB/state"; mkdir -p "$ST" "$SB/bin"
for kind in CT VM; do
  tool=$([ "$kind" = CT ] && echo pct || echo qm)
  cat > "$SB/bin/$tool" <<EOF
#!/bin/bash
f="$ST/$kind-\$2"
case "\$1" in
  status) [ -e "$ST/hang-$kind-\$2" ] && sleep 5
          [ -e "$ST/lie-$kind-\$2" ] && { echo "status: running"; exit 1; }
          [ -e "\$f" ] || { echo "no such guest" >&2; exit 2; }; echo "status: \$(cat "\$f")" ;;
  start)  [ -e "$ST/failstart-$kind-\$2" ] && { echo "start failed" >&2; exit 1; }
          if [ -e "$ST/appendlist" ]; then   # mimic the updater: atomic replace (tmp + mv), new inode
            l=\$(cat "$ST/appendlist"); { cat "\$l"; echo "VM 110"; } > "\$l.new"; mv -f "\$l.new" "\$l"
          fi
          echo "\$1 $kind \$2" >> "$ST/calls"
          if [ -e "$ST/crash-$kind-\$2" ]; then echo stopped > "\$f"; else echo running > "\$f"; fi ;;
  *) exit 9 ;;
esac
EOF
  chmod +x "$SB/bin/$tool"
done

NOWE=$(date +%s)
RL="$SB/run/restore-guests"; RLOG="$SB/run/log"; mkdir -p "$SB/run"
reset_state() { rm -f -- "$ST"/CT-* "$ST"/VM-* "$ST"/failstart-* "$ST"/crash-* "$ST"/hang-* "$ST"/lie-* "$ST/appendlist" "$ST/calls" "$RL" "$RL.done"; : > "$RLOG"; }
setg() { echo "$3" > "$ST/$1-$2"; }
run_pgr() { # [boot-id]
  PGR_LIST="$RL" PGR_LOG="$RLOG" PGR_BOOT_ID="${1:-$BOOT_NEW}" PGR_NOW="$NOWE" PGR_SETTLE_S=0 PGR_STATUS_TIMEOUT=2 \
    PGR_PCT="$SB/bin/pct" PGR_QM="$SB/bin/qm" bash "$PGR" >/dev/null 2>&1; echo $?; }
list_at() { printf "# boot_id $BOOT_OLD\n%b" "$1" > "$RL"; touch -d "@$2" "$RL"; }   # list_at <entries> <mtime>
calls() { [ -e "$ST/calls" ] && paste -sd'|' "$ST/calls" || echo none; }
AGO5=$((NOWE - 300))

reset_state
expect "restore: no list -> exit 0" 0 "$(run_pgr)"

reset_state; setg CT 201 stopped; setg VM 110 stopped; setg CT 300 running
list_at 'CT 201\nVM 110\nCT 300\n' "$AGO5"
expect "restore: normal run -> exit 0" 0 "$(run_pgr)"
expect "restore: only stopped guests are started" "start CT 201|start VM 110" "$(calls)"
[ ! -e "$RL" ] && [ -e "$RL.done" ] && pass "restore: success archives the list to .done" || fail "restore: list not archived"

reset_state; setg CT 201 stopped
list_at 'CT 201\n' "$AGO5"
expect "restore: same boot_id (no reboot yet) -> refuse" 1 "$(run_pgr "$BOOT_OLD")"
expect "restore: same boot_id -> nothing started" none "$(calls)"
[ -e "$RL" ] && pass "restore: refused list is kept (health check alarms on it)" || fail "restore: refused list was removed"

reset_state; setg CT 201 stopped
printf 'CT 201\n' > "$RL"; touch -d "@$AGO5" "$RL"
expect "restore: no boot_id header -> refuse" 1 "$(run_pgr)"
expect "restore: no header -> nothing started" none "$(calls)"

reset_state; setg CT 201 stopped
list_at 'CT 201\n' $((NOWE - 7 * 3600))
expect "restore: list 7h old (cancelled reboot) -> refuse" 1 "$(run_pgr)"
expect "restore: stale list -> nothing started" none "$(calls)"

reset_state; setg CT 201 stopped
list_at 'CT 201\n' $((NOWE - 5 * 3600))
expect "restore: list 5h old -> still restored" 0 "$(run_pgr)"

reset_state; setg CT 201 stopped
list_at 'CT 201\n' $((NOWE + 600))
expect "restore: list 10 min in the future (slow RTC at boot) -> still restored" 0 "$(run_pgr)"

reset_state; setg CT 201 stopped
list_at 'CT 201\n' $((NOWE + 2 * 3600))
expect "restore: list 2h in the future -> refuse (clock skew)" 1 "$(run_pgr)"

reset_state; setg CT 201 stopped; setg CT 202 stopped; touch "$ST/failstart-CT-202"
list_at 'CT 201\nCT 202\n' "$AGO5"
expect "restore: one start fails -> exit 1" 1 "$(run_pgr)"
expect "restore: the other guest is still started" "start CT 201" "$(calls)"
[ -e "$RL" ] && [ ! -e "$RL.done" ] && pass "restore: partial failure keeps the list" || fail "restore: partial failure archived the list"
grep -q '\[FAIL\].*could not start CT 202' "$RLOG" && pass "restore: failed start is logged as [FAIL]" || fail "restore: no [FAIL] line for the failed start"
rm -f -- "$ST/failstart-CT-202"
expect "restore: re-run after the fault clears -> exit 0" 0 "$(run_pgr)"

reset_state; setg CT 201 stopped; touch "$ST/crash-CT-201"
list_at 'CT 201\n' "$AGO5"
expect "restore: start returns 0 but guest is down at re-check -> exit 1" 1 "$(run_pgr)"
[ -e "$RL" ] && pass "restore: crashed guest keeps the list" || fail "restore: crashed guest archived the list"

reset_state; setg CT 201 stopped; touch "$ST/hang-CT-201"
list_at 'CT 201\n' "$AGO5"
expect "restore: status hangs -> times out -> exit 1" 1 "$(run_pgr)"
expect "restore: hung status -> nothing started" none "$(calls)"

reset_state; setg CT 201 stopped; touch "$ST/lie-CT-201"
list_at 'CT 201\n' "$AGO5"
expect "restore: status prints 'running' but exits non-zero -> not trusted, exit 1" 1 "$(run_pgr)"
[ -e "$RL" ] && pass "restore: failed status keeps the list" || fail "restore: failed status archived the list"

reset_state; setg CT 201 stopped; echo "$RL" > "$ST/appendlist"
list_at 'CT 201\n' "$AGO5"
expect "restore: list rewritten during the restore -> exit 1" 1 "$(run_pgr)"
grep -q '^VM 110$' "$RL" 2>/dev/null && [ ! -e "$RL.done" ] && pass "restore: rewritten list left pending, not archived" \
  || fail "restore: rewritten list was archived unchecked"

reset_state; setg CT 201 stopped
printf '# boot_id ------------------------------------\nCT 201\n' > "$RL"; touch -d "@$AGO5" "$RL"
expect "restore: 36-hyphen boot_id header -> refuse" 1 "$(run_pgr)"
expect "restore: bogus boot_id -> nothing started" none "$(calls)"

reset_state; setg CT 201 stopped
list_at 'CT 201\nCT 201; touch /tmp/pwned\n' "$AGO5"
expect "restore: malformed line -> exit 1" 1 "$(run_pgr)"
expect "restore: valid lines still processed beside a malformed one" "start CT 201" "$(calls)"
[ -e "$RL" ] && pass "restore: malformed list is kept" || fail "restore: malformed list removed"

reset_state
list_at 'VM 4242\n' "$AGO5"
expect "restore: unknown guest -> exit 1" 1 "$(run_pgr)"

reset_state; setg CT 205 stopped
list_at 'CT 205' "$AGO5"
expect "restore: last line without newline is processed" 0 "$(run_pgr)"
expect "restore: ... and started" "start CT 205" "$(calls)"

reset_state
list_at '' "$AGO5"
expect "restore: header-only list (nothing was running) -> exit 0" 0 "$(run_pgr)"
[ -e "$RL.done" ] && pass "restore: header-only list archived" || fail "restore: header-only list not archived"

reset_state; setg CT 201 stopped
list_at 'XX 201\n' "$AGO5"
expect "restore: unknown kind -> exit 1" 1 "$(run_pgr)"
expect "restore: unknown kind -> nothing started" none "$(calls)"

# ---------------- check_guest_restore (health check) ----------------
src=$(extract "$BHC" check_guest_restore); [ -n "$src" ] || { echo "cannot extract check_guest_restore"; exit 2; }; eval "$src"
cg() { # prints "<warns>|<last line>"
  ( NOW=$(date +%s); WARN=0
    log() { echo "$*"; }; ok() { log "[OK] $*"; }; warn() { log "[WARN] $*"; WARN=$((WARN + 1)); }
    out=$(check_guest_restore "$1" 60; echo "#$WARN")
    echo "${out##*#}|$(printf '%s\n' "$out" | grep -v '^#' | tail -1)" )
}
H="$SB/hc-list"; rm -f -- "$H"
r=$(cg "$H"); expect "health: no list -> no warning" 0 "${r%%|*}"
printf '# boot_id %s\nCT 201\nVM 110\n' "$BOOT_OLD" > "$H"; touch -d '10 minutes ago' "$H"
r=$(cg "$H"); expect "health: fresh list (reboot in progress) -> no warning" 0 "${r%%|*}"
touch -d '90 minutes ago' "$H"
r=$(cg "$H"); expect "health: list older than grace -> warn" 1 "${r%%|*}"
case "$r" in *"2 guest(s)"*) pass "health: warning counts guests, not the header";; *) fail "health: wrong count: $r";; esac
touch -d '30 minutes' "$H"
r=$(cg "$H"); expect "health: future-dated list -> warn (clock skew), not OK" 1 "${r%%|*}"
touch -d '90 minutes ago' "$H"

E2E_LOG="$SB/bhc.log"; M="$SB/marker"; date +%s > "$M"
BHC_LOG="$E2E_LOG" BHC_UPDATE_MARKER="$M" BHC_RESTORE_LIST="$H" bash "$BHC" >/dev/null 2>&1; rc=$?
grep -q '\[WARN\] 2 guest(s) from the last update reboot were not restored' "$E2E_LOG" \
  && pass "e2e: stale restore list -> [WARN] line OpenClaw forwards" || fail "e2e: no [WARN] for a stale restore list"
[ "$rc" -ge 1 ] && pass "e2e: stale restore list -> non-zero exit ($rc)" || fail "e2e: exit 0 despite a stale restore list"
: > "$E2E_LOG"
BHC_SKIP_UPDATER_CHECK=1 BHC_LOG="$E2E_LOG" BHC_UPDATE_MARKER="$M" BHC_RESTORE_LIST="$H" bash "$BHC" >/dev/null 2>&1
grep -q 'guest(s) from the last update' "$E2E_LOG" && fail "e2e: skip flag did not skip the restore check" \
  || pass "e2e: BHC_SKIP_UPDATER_CHECK=1 also skips the restore check"
[ -e "$H" ] && pass "e2e: health check never deletes the restore list" || fail "e2e: health check removed the list"

echo
echo "ran: $((PASS + FAILS))  failures: $FAILS"
[ "$FAILS" -eq 0 ]
