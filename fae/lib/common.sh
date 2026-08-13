#!/bin/bash
# common.sh — host-side helpers for the FAE practice lab deployer.
# Sourced by deploy.sh ON THE PROXMOX HOST (not inside containers).
# Container-side setup.sh/break.sh scripts are deliberately self-contained.

MGMT_GW="192.168.10.1"
MGMT_IF="eth0"

# ---------- output ----------
# Colour only when attached to a terminal: deploy output is a natural candidate
# for tee-ing to a log or piping into OpenClaw's Discord reporting, and raw
# escape sequences corrupt those artifacts. (D17)
if [ -t 1 ]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'; _c_rst=$'\033[0m'
else
  _c_red=''; _c_grn=''; _c_ylw=''; _c_blu=''; _c_rst=''
fi
# All four go to stdout. Splitting err/warn to stderr means a redirected log can
# show a [FAIL] detached from the operation it describes. (M8)
log()  { printf '%s[*]%s %s\n' "$_c_blu" "$_c_rst" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$_c_grn" "$_c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_c_ylw" "$_c_rst" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$_c_red" "$_c_rst" "$*"; }
die()  { err "$*"; exit 1; }

# ---------- safety ----------
# Guests that must NEVER be touched by this deployer. A typo in a CTID argument
# must not be able to destroy the production web server or the VM templates.
PROTECTED_IDS="100 300 900 901"
LAB_IDS="201 202 203 204 205 206 207"

assert_not_protected() {
  local id="$1" p
  for p in $PROTECTED_IDS; do
    [ "$id" = "$p" ] && die "REFUSING to operate on protected guest $id (production/template)."
  done
  return 0
}

assert_lab_id() {
  local id="$1" p
  for p in $LAB_IDS; do
    [ "$id" = "$p" ] && return 0
  done
  die "CTID $id is not a lab container (expected one of: $LAB_IDS)"
}

# Single mandatory gate, called INSIDE every helper that touches a CTID.
# Previously the guards lived only in create_ct/reset_lab/destroy_lab, so safety
# depended on every present and future caller remembering to check. One typo'd
# helper call (ct_stop_wait 300, snap_rollback 300) would have bypassed them
# entirely and operated on the production web server. Guard at the boundary
# where pct is actually invoked, not at the call sites.
assert_safe_ctid() {
  local id="${1:-}"
  case "$id" in
    ''|*[!0-9]*) die "invalid CTID '$id' (must be numeric)" ;;
  esac
  assert_not_protected "$id"
  assert_lab_id "$id"
}

# ---------- container helpers ----------
# NOTE: every pct call redirects stdin from /dev/null. These helpers are called
# from `while read` loops fed by a here-string; without this, pct (and anything
# it execs in the container) inherits that here-string as stdin and eats the
# rows the loop still needs — silently skipping containers. (C5)
ct_exists()  { assert_safe_ctid "$1"; pct status "$1" </dev/null >/dev/null 2>&1; }
ct_running() { assert_safe_ctid "$1"; [ "$(pct status "$1" </dev/null 2>/dev/null | awk '{print $2}')" = "running" ]; }

ct_start_wait() {
  # Fresh containers accept `pct start` well before init is ready, so poll
  # `pct exec true` rather than sleeping a fixed amount.
  local id="$1" i
  assert_safe_ctid "$id"
  ct_running "$id" || pct start "$id" </dev/null >/dev/null 2>&1
  for i in $(seq 1 30); do
    pct exec "$id" -- true </dev/null >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

ct_stop_wait() {
  local id="$1" i
  assert_safe_ctid "$id"
  ct_running "$id" || return 0
  pct stop "$id" </dev/null >/dev/null 2>&1
  for i in $(seq 1 20); do
    ct_running "$id" || return 0
    sleep 1
  done
  return 1
}

# Push a script into a container and run it. Returns the script's exit code.
# Scripts land in /root/ so the learner can inspect them afterwards.
ct_run_script() {
  local id="$1" src="$2" dest="$3" out; shift 3
  assert_safe_ctid "$id"
  [ -f "$src" ] || { err "script not found: $src"; return 1; }
  if ! out=$(pct push "$id" "$src" "$dest" --perms 755 </dev/null 2>&1); then
    err "push failed: $src -> CT$id:$dest: $out"; return 1
  fi
  pct exec "$id" -- bash "$dest" "$@" </dev/null
}

# ---------- mgmt-path guard ----------
# The SACRED INVARIANT: eth0 + the default route via 192.168.10.1 are the
# learner's SSH lifeline over Tailscale. Faults live only on eth1.
#
# This is the independent host-side backstop, so it must be at least as strict
# as the in-container guard. Earlier version used an unanchored `grep -q` on an
# unescaped IP and a prefix match on the default route — which would happily
# pass a default route via 192.168.10.199, or one leaving via tun0/eth1. (C4)
assert_mgmt_intact() {
  local id="$1" expected_ip="$2" out routes n_def bad_def
  assert_safe_ctid "$id"

  out=$(pct exec "$id" -- ip -4 addr show dev "$MGMT_IF" </dev/null 2>/dev/null) \
    || { err "CT $id: cannot read $MGMT_IF"; return 1; }
  # Compare the address field exactly rather than substring-matching anywhere in
  # `ip addr` output (which would also match a brd field or a secondary addr).
  printf '%s\n' "$out" | awk -v want="$expected_ip" '
    $1=="inet" { split($2,a,"/"); if (a[1]==want) found=1 }
    END { exit(found?0:1) }' \
    || { err "CT $id: $MGMT_IF lost $expected_ip"; return 1; }

  # A substring test like `grep -qF "via GW dev eth0"` passes as soon as ONE
  # matching default exists — it says nothing about a SECOND default route (say
  # via eth1 with a lower metric) that would actually win and sever SSH. So
  # parse every default and require exactly one, with the exact gw and dev.
  routes=$(pct exec "$id" -- ip -4 route show default </dev/null 2>/dev/null) \
    || { err "CT $id: cannot read routing table"; return 1; }
  n_def=$(printf '%s\n' "$routes" | grep -c '^default') || true
  if [ "${n_def:-0}" -ne 1 ]; then
    err "CT $id: expected exactly 1 IPv4 default route, found ${n_def:-0}:"
    printf '%s\n' "$routes" | sed 's/^/        /'
    return 1
  fi
  bad_def=$(printf '%s\n' "$routes" | awk -v gw="$MGMT_GW" -v dev="$MGMT_IF" '
    $1=="default" {
      g=""; d=""
      for (i=2;i<=NF;i++) { if ($i=="via") g=$(i+1); if ($i=="dev") d=$(i+1) }
      if (g!=gw || d!=dev) print "gw="g" dev="d
    }')
  if [ -n "$bad_def" ]; then
    err "CT $id: default route is not via ${MGMT_GW} dev ${MGMT_IF} ($bad_def)"
    return 1
  fi

  ok "CT $id mgmt path intact ($expected_ip + single default via $MGMT_GW dev $MGMT_IF)"
  return 0
}

# ---------- snapshots ----------
SNAP_NAME="lab_armed"

# grep -qw throughout: a bare `grep -q lab_armed` also scans the description
# column, so a snapshot merely *described* as lab_armed was a false positive. (C7)
snap_present() { assert_safe_ctid "$1"; pct listsnapshot "$1" </dev/null 2>/dev/null | awk '{print $2}' | grep -qx "$SNAP_NAME"; }

# PVE has no snapshot rename, so a true atomic swap isn't available. The old
# snapshot must be removed before the new one is taken; if the create then
# fails the container is left with NO reset point — so that must be loud, not
# swallowed by >/dev/null as it was before. (C7)
snap_create() {
  local id="$1" had=0 out
  assert_safe_ctid "$id"
  snap_present "$id" && had=1
  if [ "$had" -eq 1 ]; then
    if ! out=$(pct delsnapshot "$id" "$SNAP_NAME" </dev/null 2>&1); then
      err "CT $id: could not remove old '$SNAP_NAME' snapshot: $out"
      err "CT $id: refusing to continue — the existing reset point is still intact."
      return 1
    fi
  fi
  if ! out=$(pct snapshot "$id" "$SNAP_NAME" --description "Armed broken state - reset rolls back here" </dev/null 2>&1); then
    err "CT $id: snapshot '$SNAP_NAME' FAILED: $out"
    [ "$had" -eq 1 ] && err "CT $id: the previous reset point was removed — CT has NO reset point now."
    return 1
  fi
  return 0
}

# pct rollback requires a stopped container; nothing was stopping it before, and
# the error was swallowed so the operator saw a bare rc=1 with no reason. (C8)
snap_rollback() {
  local id="$1" out
  assert_safe_ctid "$id"
  snap_present "$id" || { err "CT $id has no '$SNAP_NAME' snapshot — deploy it first"; return 1; }
  ct_stop_wait "$id" || { err "CT $id would not stop — cannot roll back"; return 1; }
  if ! out=$(pct rollback "$id" "$SNAP_NAME" </dev/null 2>&1); then
    err "CT $id rollback failed: $out"; return 1
  fi
  return 0
}
