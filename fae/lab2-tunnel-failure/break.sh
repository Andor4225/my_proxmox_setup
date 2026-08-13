#!/bin/bash
# =============================================================================
# lab2-tunnel-failure :: break.sh
# -----------------------------------------------------------------------------
# Injects the lab faults on top of the WORKING baseline built by setup.sh.
#
# Runs INSIDE the container as root, e.g.:
#     pct push 203 break.sh /root/break.sh && pct exec 203 -- bash /root/break.sh a
#     pct push 204 break.sh /root/break.sh && pct exec 204 -- bash /root/break.sh b
#
# Usage: break.sh <role>       role = a (VPN server) | b (VPN client)
#
# Run setup.sh on BOTH containers first, confirm the tunnel is genuinely
# working, and only then run break.sh on BOTH. Re-running setup.sh is the
# reset path.
#
# -----------------------------------------------------------------------------
# THE FAULTS (three layers, three different discovery tools)
# -----------------------------------------------------------------------------
#   1. FORWARDING (role a only)
#      net.ipv4.ip_forward = 0, live and persisted.
#      A site-to-site gateway that does not forward still terminates the tunnel
#      perfectly - packets arrive on tun0 and are silently dropped instead of
#      being handed to the LAN side. The service stays green.
#      Found with: sysctl net.ipv4.ip_forward  /  cat /proc/sys/net/ipv4/ip_forward
#
#   2. RETURN ROUTE (role b only)
#      The scoped `route 172.16.10.0 255.255.255.0` line is commented out of the
#      client config and the live route is deleted. Requests can reach Site-A;
#      replies have no path home. Classic one-way "it pings sometimes" report.
#      Found with: ip route  /  ip route get 172.16.10.100
#      *** SCOPED ROUTE ONLY. The default route is never touched. ***
#
#   3. MTU BLACK HOLE (both roles)
#      tun-mtu is inflated to 1500, mssfix is disabled (mssfix 0) and mtu-disc
#      is set to yes in the OpenVPN config on BOTH sides, and the UNDERLAY eth1
#      MTU on role b is lowered to 1400 and persisted. A full-size tunnel packet
#      plus encap overhead no longer fits on the wire, DF stops the kernel from
#      fragmenting its way out of it, and nothing tells the sender. Small pings
#      sail through; scp and file transfers hang forever.
#      Found with: ip link  /  ping -M do -s 1400  /  tracepath
#
#   The faults are LAYERED. Fixing 1 exposes 2. Fixing 2 exposes 3. Each is
#   invisible to the tool that finds the one before it - that is the point.
#
# -----------------------------------------------------------------------------
# *** SACRED INVARIANT ***
#   eth0, its IP, and the default route via 192.168.10.1 are the learner's SSH
#   lifeline over Tailscale. NOTHING in this script may touch them. There is no
#   `ip route add default` / `ip route del default` here, no route deletion that
#   is not explicitly qualified by the far-site prefix, and no OpenVPN directive
#   that could push or install a default route.
#
#   The script ENDS with a MGMT GUARD that asserts the lifeline is intact and
#   fails loudly (exit 1) if it is not.
#
# set -e is deliberately NOT used - a partially applied fault set must still
# reach the MGMT GUARD at the bottom. That guard is the most important line in
# the file and it must always run.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        MGMT_IP="192.168.10.203"
        HOSTNAME_EXPECTED="lab-vpn-a"
        VPN_ROLE="server"
        FAR_LAN_CIDR="172.16.20.0/24"
        ;;
    b)
        MGMT_IP="192.168.10.204"
        HOSTNAME_EXPECTED="lab-vpn-b"
        VPN_ROLE="client"
        FAR_LAN_CIDR="172.16.10.0/24"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>" >&2
        exit 2
        ;;
esac

LAB_IF="eth1"
MGMT_IF="eth0"
MGMT_GW="192.168.10.1"

OVPN_DIR="/etc/openvpn"
OVPN_CONF="${OVPN_DIR}/${VPN_ROLE}.conf"
OVPN_UNIT="openvpn@${VPN_ROLE}"

LAB_STATE_DIR="/etc/lab-vpn"
MTU_FILE="${LAB_STATE_DIR}/eth1.mtu"
NETPREP_UNIT="lab-netprep.service"

# Deliberately innocuous filename. A candidate who greps for something obviously
# named "fault" finds nothing; a candidate who reads sysctl output finds the
# truth. Note the "zz" - sysctl.d is applied in lexical order, so this drop-in
# must sort AFTER 99-lab-vpn.conf (which sets ip_forward=1) in order to win.
FAULT_SYSCTL="/etc/sysctl.d/99-zz-lab-tuning.conf"

BAD_UNDERLAY_MTU=1400          # role b only - the shrunken carrier link
BAD_TUN_MTU=1500               # both roles - inflated, no longer fits inside 1400
APPLIED=""                     # fault indices actually applied, for the summary

echo "=============================================================="
echo " lab2-tunnel-failure break :: role=${ROLE} (${HOSTNAME_EXPECTED})"
echo "=============================================================="

# --- Pre-flight: refuse to run on an un-provisioned container ----------------
# Breaking a box that was never built produces a confusing lab, not a hard one.
if [ ! -f "$OVPN_CONF" ]; then
    echo "ERROR: ${OVPN_CONF} not found. Run setup.sh ${ROLE} first." >&2
    exit 2
fi

# --- Pre-flight: IDENTITY ASSERTION  *** must stay above every fault block ***
#
# The two deploy command lines differ by a handful of characters (203/204,
# a/b), so a copy-paste slip is the most likely operator error here.
#
# WHY THIS IS ITS OWN CHECK rather than being left to the MGMT GUARD at the
# bottom: the guard's job is to answer "did I break the lifeline?". A wrong-role
# invocation would make it answer YES - and its recovery banner would then tell
# the operator to add ${MGMT_IP}/24 to a container that is not supposed to have
# it, creating a duplicate-IP collision with the OTHER half of the lab, under a
# banner engineered to make them act fast. Catching the mismatch here keeps the
# guard's failure meaning exactly what its banner says.
#
# Fail fast, before any fault is applied. Only READS eth0.
if ! grep -qF "inet ${MGMT_IP}/" <<< "$(ip -4 addr show dev "$MGMT_IF" 2>/dev/null)"; then
    echo "" >&2
    echo "ERROR: role '${ROLE}' expects ${MGMT_IP} on ${MGMT_IF}, not found here." >&2
    echo "       This is the WRONG CONTAINER for this role. NOTHING was changed." >&2
    echo "       The management lifeline is FINE - do not run any recovery commands." >&2
    echo "       Expected: ${HOSTNAME_EXPECTED} (${MGMT_IP})" >&2
    echo "       Actual ${MGMT_IF} addressing:" >&2
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null | sed 's/^/         /' >&2
    echo "       Re-check the CTID / role pairing:  CT 203 -> a   CT 204 -> b" >&2
    exit 2
fi

# =============================================================================
# FAULT 1 - IP forwarding disabled  (role a / the tunnel server only)
#
# WHY THIS SIDE: Site-A is where traffic from Site-B has to cross from tun0 onto
# the Site-A office LAN. Turn off forwarding and that hop-over silently stops.
# The tunnel is unaffected - OpenVPN terminates traffic locally, so the daemon
# never notices and systemd keeps reporting active (running).
#
# Persisted via a sysctl.d drop-in so a reboot cannot accidentally "fix" the lab.
# Note this only ever writes net.ipv4.ip_forward - it does not touch addressing
# or routing, so the management lifeline is structurally unaffected.
# =============================================================================
if [ "$ROLE" = "a" ]; then
    echo "[*] Applying fault 1 ..."
    mkdir -p /etc/sysctl.d
    cat > "$FAULT_SYSCTL" << 'EOF'
# Network tuning - applied during the inter-site link maintenance window.
# (Do not remove without checking with Network Operations first.)
net.ipv4.ip_forward = 0
EOF
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 \
        || echo "    WARNING: live sysctl write failed"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "0" ]; then
        echo "    fault 1 applied (live + persisted in ${FAULT_SYSCTL})"
        APPLIED="${APPLIED} 1"
    else
        echo "    WARNING: fault 1 did NOT take effect"
    fi

    # Persistence caveat: `sysctl --system` applies /etc/sysctl.conf LAST, after
    # every sysctl.d drop-in. Debian ships net.ipv4.ip_forward commented out
    # there - but this is a privileged LXC on a lab host, exactly the sort of
    # container where someone uncomments it while setting up routing for
    # something else. If they did, fault 1 evaporates on every reboot and the
    # lab silently drops from three layers to two with no warning anywhere.
    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf 2>/dev/null; then
        echo "    WARNING: /etc/sysctl.conf sets net.ipv4.ip_forward and is applied" >&2
        echo "             AFTER /etc/sysctl.d/*. Fault 1 will NOT survive a reboot" >&2
        echo "             or 'sysctl --system'. Comment that line out first." >&2
    fi
fi

# =============================================================================
# FAULT 2 - Missing return route to the far site LAN  (role b / the client only)
#
# WHY THIS SIDE: Site-B is the client. Strip its scoped route to the Site-A
# office LAN and Site-B can no longer originate or return traffic toward it.
# The tunnel itself is up and the tunnel endpoints still ping each other, which
# is exactly the "sometimes it works" confusion in the ticket.
#
# Persisted by commenting the `route` line out of the OpenVPN client config, so
# the route is not re-created on service restart or on reboot.
#
# *** SCOPING NOTE - read before editing this block ***
# The only route ever deleted here is qualified by the far-site prefix
# ${FAR_LAN_CIDR}. There is no `ip route del default`, no `ip route flush`, and
# no unqualified delete anywhere in this script. The default route via
# ${MGMT_GW} and everything on eth0 are untouched, and the MGMT GUARD at the
# bottom proves it before the script exits.
# =============================================================================
if [ "$ROLE" = "b" ]; then
    echo "[*] Applying fault 2 ..."

    # Persist: comment out the scoped route directive in the client config.
    # The trailing [[:space:]] is deliberate - it anchors the match to the exact
    # network address and stops the pattern from also swallowing a hypothetical
    # `route 172.16.10.01 ...` or similar near-miss line.
    if grep -qE '^route[[:space:]]+172\.16\.10\.0[[:space:]]' "$OVPN_CONF"; then
        sed -i 's|^route[[:space:]]\+172\.16\.10\.0[[:space:]].*|# route 172.16.10.0 255.255.255.0|' "$OVPN_CONF"
        echo "    commented the scoped far-LAN route out of ${OVPN_CONF}"
    else
        echo "    scoped far-LAN route already absent from ${OVPN_CONF}"
    fi

    # Apply live. Loop because OpenVPN may have installed more than one entry;
    # every delete is explicitly qualified by the far-site prefix.
    DELETED=0
    while ip -4 route show "$FAR_LAN_CIDR" 2>/dev/null | grep -q .; do
        ip route del "$FAR_LAN_CIDR" 2>/dev/null || break
        DELETED=$((DELETED + 1))
    done
    if ip -4 route show "$FAR_LAN_CIDR" 2>/dev/null | grep -q .; then
        echo "    WARNING: route to ${FAR_LAN_CIDR} still present after ${DELETED} delete(s)"
    else
        echo "    fault 2 applied (live route to ${FAR_LAN_CIDR} removed, ${DELETED} entr(y/ies))"
        APPLIED="${APPLIED} 2"
    fi
fi

# =============================================================================
# FAULT 3 - MTU black hole  (BOTH roles)
#
# Two halves that only bite together:
#   3a (both)  tun-mtu 1500 + mssfix 0 in the OpenVPN config. A full-size tunnel
#              payload plus UDP/IP/OpenVPN encapsulation now exceeds the carrier
#              link, and with mssfix disabled TCP is no longer clamped down to
#              something that fits.
#   3b (b)     The underlay eth1 MTU drops to 1400 - the plausible aftermath of
#              the "carrier maintenance window" the ticket mentions.
#
# Result: small packets pass, large ones vanish with no ICMP feedback the app
# ever sees. Ping works. scp hangs. This is the single most commonly
# misdiagnosed ticket in the field, which is why it is the last layer.
#
# Deliberately absent: the `fragment` directive. Adding it would let OpenVPN
# fragment internally and quietly paper over the whole fault.
#
# Persistence: the config edits persist by definition; the eth1 MTU persists via
# /etc/lab-vpn/eth1.mtu, which lab-netprep.service re-applies at every boot.
# That file governs eth1 ONLY - it can never influence eth0 or the default route.
# =============================================================================
echo "[*] Applying fault 3 ..."
F3_CONF_OK=0
F3_MTU_OK=1        # role a has no underlay half; treat as satisfied

# --- 3a: inflate the tunnel MTU and disable the TCP clamp (both roles) -------
if grep -qE '^tun-mtu[[:space:]]' "$OVPN_CONF"; then
    sed -i "s|^tun-mtu[[:space:]].*|tun-mtu ${BAD_TUN_MTU}|" "$OVPN_CONF"
else
    echo "tun-mtu ${BAD_TUN_MTU}" >> "$OVPN_CONF"
fi
if grep -qE '^mssfix[[:space:]]' "$OVPN_CONF"; then
    sed -i 's|^mssfix[[:space:]].*|mssfix 0|' "$OVPN_CONF"
else
    echo "mssfix 0" >> "$OVPN_CONF"
fi

# mtu-disc yes sets DF on the OUTER (encapsulating) UDP packets.
#
# WHY THIS MATTERS: without it, an oversized outer packet may simply be
# IP-fragmented by the kernel and still arrive. That turns a crisp black hole
# into "a bit slow", and the candidate never sees the classic symptom. With DF
# set, the oversized packet is dropped instead of fragmented and large payloads
# genuinely disappear - while the daemon keeps running and systemd keeps
# reporting active (running), which is the red herring the lab depends on.
#
# Note the pairing: `fragment` is deliberately NOT used anywhere. It would let
# OpenVPN fragment internally and quietly repair this fault.
if grep -qE '^mtu-disc[[:space:]]' "$OVPN_CONF"; then
    sed -i 's|^mtu-disc[[:space:]].*|mtu-disc yes|' "$OVPN_CONF"
else
    echo "mtu-disc yes" >> "$OVPN_CONF"
fi

if grep -qE "^tun-mtu[[:space:]]+${BAD_TUN_MTU}\$" "$OVPN_CONF" \
   && grep -qE '^mssfix[[:space:]]+0$' "$OVPN_CONF" \
   && grep -qE '^mtu-disc[[:space:]]+yes$' "$OVPN_CONF"; then
    F3_CONF_OK=1
    echo "    ${OVPN_CONF}: tun-mtu ${BAD_TUN_MTU}, mssfix 0, mtu-disc yes"
else
    echo "    WARNING: could not confirm the tun-mtu/mssfix/mtu-disc edit in ${OVPN_CONF}"
fi

# --- 3b: shrink the underlay carrier link (role b only) ----------------------
if [ "$ROLE" = "b" ]; then
    F3_MTU_OK=0
    mkdir -p "$LAB_STATE_DIR"
    echo "$BAD_UNDERLAY_MTU" > "$MTU_FILE"          # persisted, re-applied at boot

    # Also reflect it in the declarative interfaces.d record, for the learner
    # who goes looking there. Scoped to the eth1 stanza file only.
    IFACE_FILE="/etc/network/interfaces.d/${LAB_IF}"
    if [ -f "$IFACE_FILE" ]; then
        if grep -qE '^[[:space:]]*mtu[[:space:]]' "$IFACE_FILE"; then
            sed -i "s|^[[:space:]]*mtu[[:space:]].*|    mtu ${BAD_UNDERLAY_MTU}|" "$IFACE_FILE"
        else
            echo "    mtu ${BAD_UNDERLAY_MTU}" >> "$IFACE_FILE"
        fi
    fi

    # Apply live. `ip link set eth1 mtu N` changes ONLY eth1.
    ip link set "$LAB_IF" mtu "$BAD_UNDERLAY_MTU" 2>/dev/null \
        || echo "    WARNING: live MTU change on ${LAB_IF} failed"

    CUR_MTU="$(cat "/sys/class/net/${LAB_IF}/mtu" 2>/dev/null)"
    if [ "${CUR_MTU:-0}" = "$BAD_UNDERLAY_MTU" ]; then
        F3_MTU_OK=1
        echo "    ${LAB_IF} mtu lowered to ${BAD_UNDERLAY_MTU} (live + persisted in ${MTU_FILE})"
    else
        echo "    WARNING: ${LAB_IF} mtu is ${CUR_MTU:-unknown}, expected ${BAD_UNDERLAY_MTU}"
    fi
fi

if [ "$F3_CONF_OK" -eq 1 ] && [ "$F3_MTU_OK" -eq 1 ]; then
    APPLIED="${APPLIED} 3"
fi

# =============================================================================
# Restart the tunnel and CONFIRM IT IS STILL GREEN
#
# This is load-bearing. The entire lab rests on the red herring "systemctl says
# active (running)". If the tunnel dies here the candidate gets a trivially
# different (and much easier) ticket, so a dead service is a LOUD failure.
# =============================================================================
echo "[*] Restarting ${OVPN_UNIT} ..."
systemctl restart "$OVPN_UNIT" >/dev/null 2>&1 || echo "    WARNING: restart command failed"

TUNNEL_GREEN=0
for i in $(seq 1 15); do
    if systemctl is-active --quiet "$OVPN_UNIT"; then
        TUNNEL_GREEN=1
        break
    fi
    sleep 1
done

if [ "$TUNNEL_GREEN" -eq 1 ]; then
    echo "    ${OVPN_UNIT} is active (running) - red herring intact"
else
    echo ""
    echo "##############################################################"
    echo "#  WARNING: ${OVPN_UNIT} is NOT active after the fault      "
    echo "#  injection. The lab's central red herring depends on this  "
    echo "#  service reporting active (running).                       "
    echo "#                                                            "
    echo "#  Investigate before handing the lab to a candidate:        "
    echo "#      systemctl status ${OVPN_UNIT}"
    echo "#      journalctl -u ${OVPN_UNIT} -n 50 --no-pager"
    echo "#                                                            "
    echo "#  Then re-run setup.sh ${ROLE} to reset and try again.      "
    echo "##############################################################"
    echo ""
fi

# tun0 should also still exist - a config the daemon rejects would take it away.
if ip link show tun0 >/dev/null 2>&1; then
    echo "    tun0 still present"
else
    echo "    WARNING: tun0 is missing - the daemon may have rejected the config"
fi

# --- Prove fault 3 actually BITES, not just that the config text changed ------
#
# Everything above asserts the EDIT. This asserts the EFFECT, which is the thing
# that matters: if the oversized packets are being fragmented and reassembled
# rather than dropped, the candidate gets "a bit slow" instead of "transfers
# hang dead" and the hardest layer of the lab quietly evaporates.
#
# Probing the TUNNEL ENDPOINTS (10.99.99.x) deliberately, not the site LAN
# hosts: endpoint-to-endpoint traffic is terminated locally by OpenVPN, so it is
# unaffected by faults 1 and 2 and isolates fault 3 cleanly. A site-LAN probe
# here would fail for three reasons at once and prove nothing.
#
# Expected verdict: SMALL succeeds, LARGE fails. That exact pair IS the ticket.
case "$ROLE" in
    a) TUN_PEER="10.99.99.2" ;;
    b) TUN_PEER="10.99.99.1" ;;
esac
echo "[*] Confirming fault 3 behaviour against ${TUN_PEER} ..."
SMALL_OK=0
LARGE_OK=0
for _ in $(seq 1 5); do
    ping -c1 -W2 -M do -s 64 "$TUN_PEER" >/dev/null 2>&1 && { SMALL_OK=1; break; }
    sleep 1
done
ping -c1 -W3 -M do -s 1400 "$TUN_PEER" >/dev/null 2>&1 && LARGE_OK=1

if [ "$SMALL_OK" -eq 1 ] && [ "$LARGE_OK" -eq 0 ]; then
    echo "    small OK / large FAILS - fault 3 is behaving as designed"
elif [ "$SMALL_OK" -eq 0 ]; then
    echo "    NOTE: small probe also failed. Expected if the peer has not been"
    echo "          broken yet, or is still booting. Re-check once BOTH roles"
    echo "          have run break.sh."
else
    echo "    WARNING: large probe SUCCEEDED - fault 3 is not black-holing."
    echo "             Oversized packets are getting through (fragmentation?)."
    echo "             The hardest layer of this lab is currently ineffective."
fi

# =============================================================================
# MGMT GUARD  ***  DO NOT REMOVE, DO NOT MOVE ABOVE THE FAULT BLOCKS  ***
#
# Nothing above is supposed to be able to touch eth0 or the default route.
# This asserts that claim rather than trusting it. If it ever trips, the lab is
# unsafe to hand to a candidate - the learner's SSH lifeline is what is at risk.
# =============================================================================
echo ""
echo "=== MGMT GUARD ==="

GUARD_FAIL=0

# Snapshot the state into variables FIRST, then match against the variables.
#
# WHY NOT `ip ... | grep -q ...`: this script runs under `set -o pipefail`, and
# `grep -q` exits the moment it matches, closing the pipe. If the upstream `ip`
# has not finished writing it takes SIGPIPE and exits 141, which pipefail then
# promotes to the pipeline's status - turning a SUCCESSFUL match into a FALSE
# result. In practice `ip` output fits the pipe buffer and this never fires, but
# "never fires in practice" is not good enough in the one place in this repo
# where a false positive tells the operator their lifeline is gone.
MGMT_ADDR_STATE="$(ip -4 addr show dev "$MGMT_IF" 2>/dev/null)"
DEFAULT_ROUTE_STATE="$(ip -4 route show default 2>/dev/null)"
ALL_ROUTE_STATE="$(ip -4 route show 2>/dev/null)"

# -F: match the address literally. The dots in an IP are regex wildcards
# otherwise, which is sloppy even where it cannot realistically mis-match.
if grep -qF "inet ${MGMT_IP}/" <<< "$MGMT_ADDR_STATE"; then
    echo "[OK]   ${MGMT_IF} still holds ${MGMT_IP}"
else
    echo "[FAIL] ${MGMT_IF} does NOT hold ${MGMT_IP}"
    sed 's/^/       /' <<< "$MGMT_ADDR_STATE"
    GUARD_FAIL=1
fi

if grep -qF "via ${MGMT_GW}" <<< "$DEFAULT_ROUTE_STATE"; then
    echo "[OK]   default route via ${MGMT_GW} present"
else
    echo "[FAIL] default route via ${MGMT_GW} is MISSING"
    sed 's/^/       /' <<< "$DEFAULT_ROUTE_STATE"
    GUARD_FAIL=1
fi

# Extra paranoia: the default route must not have been hijacked onto the tunnel.
#
# Checking ONLY `ip route show default` would miss the standard hijack. OpenVPN's
# redirect-gateway does not replace the default route - it installs the split
# pair 0.0.0.0/1 + 128.0.0.0/1 through the tunnel, which outrank the default by
# prefix length while never appearing in `ip route show default` at all. Match
# all three forms against the full table.
if grep -qE '^(0\.0\.0\.0/1|128\.0\.0\.0/1|default)[[:space:]].*dev (tun|tap)[0-9]' <<< "$ALL_ROUTE_STATE"; then
    echo "[FAIL] a default-equivalent route points at a tunnel interface - lifeline at risk"
    grep -E '^(0\.0\.0\.0/1|128\.0\.0\.0/1|default)[[:space:]]' <<< "$ALL_ROUTE_STATE" | sed 's/^/       /'
    GUARD_FAIL=1
fi

if [ "$GUARD_FAIL" -ne 0 ]; then
    echo ""
    echo "##############################################################"
    echo "##                                                          ##"
    echo "##   MGMT GUARD FAILED - MANAGEMENT LIFELINE COMPROMISED    ##"
    echo "##                                                          ##"
    echo "##   eth0 and/or the default route via ${MGMT_GW}"
    echo "##   are not in their expected state. Do NOT hand this lab   ##"
    echo "##   to a candidate and do NOT close this session until the  ##"
    echo "##   lifeline is restored - you may lose SSH access.         ##"
    echo "##                                                          ##"
    echo "##   Recover from the Proxmox host console:                  ##"
    echo "##       pct exec <CTID> -- ip addr add ${MGMT_IP}/24 dev eth0"
    echo "##       pct exec <CTID> -- ip route add default via ${MGMT_GW}"
    echo "##                                                          ##"
    echo "##############################################################"
    exit 1
fi

# =============================================================================
# Summary - indices only. No spoilers: the candidate may well read this output.
# =============================================================================
echo ""
echo "=== Result ==="
if [ -n "$APPLIED" ]; then
    echo "Faults applied on role '${ROLE}':${APPLIED}"
else
    echo "Faults applied on role '${ROLE}': NONE (check the warnings above)"
fi
echo "Management lifeline verified intact."
echo "Reset at any time with: bash setup.sh ${ROLE}"
exit 0
