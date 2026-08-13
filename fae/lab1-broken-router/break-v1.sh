#!/bin/bash
# =============================================================================
# lab1-broken-router :: break.sh
# -----------------------------------------------------------------------------
# Injects THREE layered networking faults into the lab, then proves the
# management lifeline is still intact.
#
# Runs INSIDE a Debian 12 privileged LXC container as root, e.g.:
#     pct push 201 break.sh /root/break.sh && pct exec 201 -- bash /root/break.sh a
#     pct push 202 break.sh /root/break.sh && pct exec 202 -- bash /root/break.sh b
#
# Usage: break.sh <role>       role = a | b
#
# FAULT DISTRIBUTION
#   role b -> faults 1 and 2
#   role a -> fault 3
#
# WHY THIS SPLIT: each fault is discovered with a DIFFERENT tool, and fixing one
# uncovers the next. The learner cannot shortcut to the end.
#
#   Fault 1 (B, `ip addr` / `tcpdump`)  - subnet mask mismatch
#           B's eth1 becomes 10.10.10.20/28, whose subnet is 10.10.10.16-31.
#           A's .10 falls OUTSIDE that range, so A (still /24) considers B
#           on-link and the echo REQUEST arrives fine - tcpdump on B shows it -
#           but B no longer has an on-link path back to .10, so the reply never
#           returns on the lab segment. The asymmetry ("packets arrive, nothing
#           comes back") is the whole teaching point: capture on both ends
#           before touching config.
#
#           PRECISION NOTE for the instructor: with fault 1 alone, B's reply is
#           not dropped for lack of any route - it falls through to B's default
#           route and leaves via the MGMT interface, where the site gateway has
#           no path to 10.10.10.0/24 and discards it. With fault 2 also armed
#           (the normal armed state) the more-specific 10.10.10.0/24 static
#           route wins and the reply goes to the phantom next-hop instead, so
#           nothing leaks out MGMT. Either way the observable symptom is the
#           same and neither case modifies MGMT configuration.
#
#   Fault 2 (B, `ip route`)             - bogus next-hop for the lab segment
#           Once the mask is fixed, B suddenly has a route back to .10 - except
#           a static route sends the lab segment at 10.10.10.254, a gateway that
#           does not exist. `ping` still fails, but now `ip route` tells the
#           story. Installed as BOTH 10.10.10.0/24 (the headline the learner
#           spots) and 10.10.10.10/32 (which guarantees it still wins after the
#           learner re-adds the connected /24 - see the long note at the
#           injection site). Both are SCOPED to the lab segment. Neither is a
#           default route, and neither can become one.
#
#   Fault 3 (A, `ip neigh`)             - poisoned permanent ARP entry
#           With B fully healthy, A's layer 3 config reads perfect and still
#           nothing works, because A has a hardcoded PERMANENT ARP entry mapping
#           10.10.10.20 to a MAC that belongs to nobody. Frames leave A addressed
#           to a phantom. Only `ip neigh` reveals it. Teaches that a correct
#           routing table is not the same as a correct forwarding path.
#
# *** SACRED INVARIANT ***
#   eth0, its IP, and the default route via 192.168.10.1 are the learner's SSH
#   lifeline over Tailscale. NOTHING here may modify them.
#     - No bare `ip route add default` / `ip route del default` exists in this
#       file or in the persistence script it generates.
#     - Every fault is scoped explicitly to eth1 or the 10.10.10.0/24 prefix.
#     - The script ends with a MGMT GUARD that hard-fails if either the eth0
#       address or the default route is not exactly as expected.
#   The persistence mechanism (systemd oneshot) runs the same guard on every
#   boot, so the invariant holds unattended too.
#
# set -e is deliberately NOT used - a single failed injection must not leave the
# container half-configured with the guard never reached.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        MGMT_IP="192.168.10.201"
        FAULTS_APPLIED="3"
        ;;
    b)
        MGMT_IP="192.168.10.202"
        FAULTS_APPLIED="1, 2"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>" >&2
        exit 2
        ;;
esac

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
FAULT_SCRIPT="/usr/local/sbin/lab-faults.sh"
FAULT_UNIT="lab-faults.service"
UNIT_PATH="/etc/systemd/system/${FAULT_UNIT}"

# =============================================================================
# MGMT GUARD - the single most important function in this repo.
# Asserts eth0 still holds the expected 192.168.10.20X address AND that a
# default route via 192.168.10.1 out of eth0 exists. Read-only: it never repairs
# anything, because a guard that mutates state can mask the bug it is meant to
# catch. The route match includes `dev eth0` so a default pointing out some other
# interface cannot silently satisfy the check.
# =============================================================================
mgmt_guard() {
    local ctx="${1:-}"
    local addr_ok=1 route_ok=1

    ip -4 addr show dev "$MGMT_IF" 2>/dev/null | grep -q "inet ${MGMT_IP}/"            || addr_ok=0
    ip -4 route show default 2>/dev/null | grep -qF "via ${MGMT_GW} dev ${MGMT_IF}"     || route_ok=0

    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ]; then
        echo "[OK]   MGMT GUARD${ctx:+ (${ctx})}: ${MGMT_IF} holds ${MGMT_IP}, default via ${MGMT_GW}"
        return 0
    fi

    echo ""
    echo "################################################################"
    echo "#                                                              #"
    echo "#   FAIL - MANAGEMENT LIFELINE COMPROMISED                     #"
    echo "#                                                              #"
    echo "################################################################"
    echo "#  Context      : ${ctx:-final check}"
    echo "#  Expected addr: ${MGMT_IF} = ${MGMT_IP}/24    -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    echo "#  Expected rt  : default via ${MGMT_GW}        -> $([ "$route_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    echo "################################################################"
    echo ""
    echo "--- ${MGMT_IF} addresses ---"
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null || echo "(none)"
    echo "--- default routes ---"
    ip -4 route show default 2>/dev/null || echo "(none)"
    echo ""
    echo "DO NOT continue. Restore management access from the Proxmox console:"
    echo "    pct exec <CTID> -- ip addr add ${MGMT_IP}/24 dev ${MGMT_IF}"
    echo "    pct exec <CTID> -- ip route add default via ${MGMT_GW} dev ${MGMT_IF}"
    echo ""
    exit 1
}

echo "=============================================================="
echo " lab1-broken-router break :: role=${ROLE}"
echo "=============================================================="

# Pre-flight: refuse to touch anything if the lifeline is already wrong.
mgmt_guard "pre-flight"

if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
    echo "ERROR: ${LAB_IF} not present - run setup.sh first and check the CT's vmbr1 NIC" >&2
    exit 3
fi

# =============================================================================
# Generate the persistence script.
#
# The SAME script both applies the faults now and re-applies them at boot, so
# there is exactly one definition of each fault. A reboot must not accidentally
# "fix" the lab - the reporter in the ticket already tried that.
#
# The generated script carries its own copy of the MGMT GUARD, so the invariant
# is enforced on every unattended boot, not just when a human runs break.sh.
# =============================================================================
echo "[*] Writing persistence script ${FAULT_SCRIPT} ..."
mkdir -p "$(dirname "$FAULT_SCRIPT")"

{
    echo '#!/bin/bash'
    echo '# GENERATED BY break.sh - lab1-broken-router fault persistence.'
    echo '# Re-applies the lab faults at boot. Scoped to eth1 / 10.10.10.0/24 ONLY.'
    echo '# Never touches eth0, its address, or the default route.'
    echo "ROLE_DEFAULT=\"${ROLE}\""
    echo "MGMT_IP=\"${MGMT_IP}\""
    cat << 'LAB_FAULTS_BODY'
set -uo pipefail

# The role is baked in at generation time, but an explicit argument wins so the
# script behaves as its own command line advertises (systemd passes it too).
ROLE="${1:-$ROLE_DEFAULT}"

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
LAB_NET="10.10.10.0/24"
BOGUS_GW="10.10.10.254"
BOGUS_MAC="02:de:ad:be:ef:01"
PEER_A="10.10.10.10"
PEER_B="10.10.10.20"
B_BROKEN_CIDR="10.10.10.20/28"

RC=0
log() { echo "lab-faults[$ROLE]: $*"; }
fail() { log "ERROR: $*"; RC=1; }

# --- Guard (identical contract to break.sh's) --------------------------------
# grep -F so the dots are literal; the route match includes `dev $MGMT_IF` so a
# default route out of some other interface cannot silently satisfy it.
mgmt_guard() {
    local ctx="${1:-}"
    local addr_ok=1 route_ok=1
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null | grep -qF "inet ${MGMT_IP}/"            || addr_ok=0
    ip -4 route show default 2>/dev/null | grep -qF "via ${MGMT_GW} dev ${MGMT_IF}"     || route_ok=0
    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ]; then
        log "MGMT GUARD OK${ctx:+ ($ctx)}"
        return 0
    fi
    log "########################################################"
    log "#  FAIL - MANAGEMENT LIFELINE COMPROMISED (${ctx:-final})"
    log "#  ${MGMT_IF}=${MGMT_IP} -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    log "#  default via ${MGMT_GW} dev ${MGMT_IF} -> $([ "$route_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    log "########################################################"
    exit 1
}

# --- Boot-ordering safety ----------------------------------------------------
# In LXC, eth1 EXISTS from container start, so waiting for the link to appear
# provides no delay at all and we would race ifupdown: we would set /28, then
# `ifup eth1` would add the baseline /24 on top and quietly undo fault 1.
# Wait for the interface to actually carry a lab ADDRESS, which only happens
# once ifupdown has finished with it.
LAB_READY=0
for i in $(seq 1 30); do
    if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -qE 'inet 10\.10\.10\.'; then
        LAB_READY=1
        break
    fi
    sleep 1
done
if [ "$LAB_READY" -ne 1 ]; then
    if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
        log "ERROR: $LAB_IF never appeared; aborting without changes"
        exit 1
    fi
    log "WARNING: $LAB_IF has no 10.10.10.x address after 30s; injecting anyway"
fi

mgmt_guard "pre-inject"

case "$ROLE" in
  b)
    # --- FAULT 1: subnet mask mismatch ---------------------------------------
    # /28 spans 10.10.10.16-31, so A's .10 is outside B's subnet. A's request
    # lands (A still thinks B is on-link) but B has no on-link path back to .10,
    # so no reply returns on the lab segment.
    # Scoped: `flush` names eth1 explicitly and touches nothing else.
    ip link set "$LAB_IF" up 2>/dev/null || true
    ip addr flush dev "$LAB_IF" 2>/dev/null || true
    ip addr add "$B_BROKEN_CIDR" dev "$LAB_IF" 2>/dev/null || true
    if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -qF "inet ${B_BROKEN_CIDR}"; then
        log "fault 1 applied"
    else
        fail "fault 1 did NOT take - ${LAB_IF} is not ${B_BROKEN_CIDR}"
    fi

    # --- FAULT 2: bogus next-hop for the lab segment --------------------------
    # `replace` makes this idempotent. `onlink` is required because BOGUS_GW is
    # not inside B's (now /28) connected subnet, so the kernel would otherwise
    # reject the nexthop as unreachable.
    #
    # TWO routes on purpose. The /24 is the headline fault - it is what the
    # learner sees in `ip route` and it is scoped to the lab prefix. But once
    # the learner fixes fault 1 and re-adds 10.10.10.20/24, the kernel inserts a
    # CONNECTED 10.10.10.0/24 with the same prefix length and the same metric,
    # and longest-prefix match can no longer arbitrate between them - which one
    # wins becomes a FIB insertion-order detail. That would let fault 2 silently
    # vanish and collapse a three-fault lab into two. The /32 for A's address is
    # strictly more specific, so it deterministically wins in every case.
    #
    # BOTH are scoped to the lab segment. Neither is, or can become, a default
    # route.
    if ! ip route replace "$LAB_NET" via "$BOGUS_GW" dev "$LAB_IF" onlink 2>/dev/null; then
        fail "could not install ${LAB_NET} via ${BOGUS_GW}"
    fi
    if ! ip route replace "${PEER_A}/32" via "$BOGUS_GW" dev "$LAB_IF" onlink 2>/dev/null; then
        fail "could not install ${PEER_A}/32 via ${BOGUS_GW}"
    fi
    # Postcondition: traffic to A must actually resolve through the phantom.
    if ip route get "$PEER_A" 2>/dev/null | grep -qF "via ${BOGUS_GW}"; then
        log "fault 2 applied"
    else
        fail "fault 2 did NOT take - path to ${PEER_A} does not use ${BOGUS_GW}"
        ip route get "$PEER_A" 2>/dev/null | sed 's/^/         /'
    fi
    ;;
  a)
    # --- FAULT 3: poisoned permanent ARP entry -------------------------------
    # A's L3 config is pristine; only the neighbour table is lying. `replace`
    # plus `nud permanent` means it is idempotent and never ages out, so the
    # learner cannot wait it away. Scoped to a single lab-segment address.
    ip link set "$LAB_IF" up 2>/dev/null || true
    ip neigh replace "$PEER_B" lladdr "$BOGUS_MAC" dev "$LAB_IF" nud permanent 2>/dev/null || true
    if ip -4 neigh show "$PEER_B" dev "$LAB_IF" 2>/dev/null | grep -qF "$BOGUS_MAC"; then
        log "fault 3 applied"
    else
        fail "fault 3 did NOT take - no ${BOGUS_MAC} entry for ${PEER_B}"
        ip -4 neigh show "$PEER_B" dev "$LAB_IF" 2>/dev/null | sed 's/^/         /'
    fi
    ;;
  *)
    log "ERROR: unknown role '$ROLE'"
    exit 2
    ;;
esac

mgmt_guard "post-inject"
[ "$RC" -eq 0 ] || log "one or more faults failed to apply - lab is NOT correctly armed"
exit "$RC"
LAB_FAULTS_BODY
} > "$FAULT_SCRIPT"

chmod 700 "$FAULT_SCRIPT"

# Syntax-check the generated script before we ever enable a unit that runs it.
if ! bash -n "$FAULT_SCRIPT"; then
    echo "ERROR: generated ${FAULT_SCRIPT} failed syntax check - not enabling unit" >&2
    exit 4
fi

# =============================================================================
# systemd oneshot so the faults survive a reboot.
#
# ORDERING MATTERS: `network-online.target` alone does NOT order us after
# ifupdown - without an enabled *-wait-online unit it can be reached almost
# immediately. If we run before `networking.service`, ifupdown re-adds the
# baseline /24 on top of our /28 and a reboot silently repairs fault 1, which is
# exactly what the ticket promises will not happen. Order against
# networking.service explicitly, and the generated script additionally waits for
# eth1 to carry an address before it injects.
#
# RemainAfterExit keeps the unit "active" once applied, which is also a cheap
# way for the instructor to see at a glance whether the lab is armed.
# =============================================================================
echo "[*] Installing ${FAULT_UNIT} ..."
cat > "$UNIT_PATH" << EOF
[Unit]
Description=lab1-broken-router fault injection (eth1 / 10.10.10.0/24 only)
After=network-online.target networking.service
Wants=network-online.target
After=systemd-networkd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FAULT_SCRIPT} ${ROLE}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT_PATH"

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "$FAULT_UNIT" >/dev/null 2>&1 || echo "    WARNING: could not enable ${FAULT_UNIT}"

# =============================================================================
# Apply the faults now, via the exact same code path that runs at boot.
# =============================================================================
echo "[*] Injecting faults ..."
if bash "$FAULT_SCRIPT" "$ROLE"; then
    INJECT_RC=0
else
    INJECT_RC=$?
    echo "    WARNING: fault script exited ${INJECT_RC}"
fi

# =============================================================================
# MGMT GUARD - final, mandatory.
# Runs before the exit-code decision below, so the lifeline is always asserted
# no matter how the injection went.
# =============================================================================
echo ""
mgmt_guard "post-break final"

# =============================================================================
# Report. Indices only - no spoilers on stdout, the learner may be watching.
# =============================================================================
echo ""
if [ "$INJECT_RC" -eq 0 ]; then
    echo "=============================================================="
    echo " Role '${ROLE}' armed. Fault indices applied: ${FAULTS_APPLIED}"
    echo " Persistence: ${FAULT_UNIT} (enabled, survives reboot)"
    echo " Reset to working state: bash /root/setup.sh ${ROLE}"
    echo "=============================================================="
    exit 0
else
    echo "=============================================================="
    echo " Role '${ROLE}' NOT correctly armed (injector exit ${INJECT_RC})."
    echo " Intended fault indices: ${FAULTS_APPLIED}"
    echo " Management lifeline is intact, but the lab state is unreliable."
    echo " Reset and retry: bash /root/setup.sh ${ROLE} && bash /root/break.sh ${ROLE}"
    echo "=============================================================="
    exit 1
fi
