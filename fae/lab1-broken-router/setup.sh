#!/bin/bash
# =============================================================================
# lab1-broken-router :: setup.sh
# -----------------------------------------------------------------------------
# Builds the WORKING baseline state for the "Broken Router" networking lab.
#
# Runs INSIDE a Debian 12 privileged LXC container as root, e.g.:
#     pct push 201 setup.sh /root/setup.sh && pct exec 201 -- bash /root/setup.sh a
#     pct push 202 setup.sh /root/setup.sh && pct exec 202 -- bash /root/setup.sh b
#
# Usage: setup.sh <role>       role = a | b
#
# TOPOLOGY (fixed, do not change):
#   CT 201 lab-router-a : eth0 192.168.10.201/24 gw 192.168.10.1 (vmbr0, MGMT)
#                         eth1 10.10.10.10/24    no gateway      (vmbr1, LAB)
#   CT 202 lab-router-b : eth0 192.168.10.202/24 gw 192.168.10.1 (vmbr0, MGMT)
#                         eth1 10.10.10.20/24    no gateway      (vmbr1, LAB)
#
# *** SACRED INVARIANT ***
#   eth0, its IP, and the default route via 192.168.10.1 are the learner's SSH
#   lifeline over Tailscale. NOTHING in this script may touch them. Every write
#   below is scoped explicitly to eth1 or the 10.10.10.0/24 prefix. There is no
#   bare `ip route add default` / `ip route del default` anywhere in this repo,
#   and there must never be one.
#
# This script is also the RESET tool: re-running it after break.sh removes the
# injected faults and returns the container to the known-good state.
#
# set -e is deliberately NOT used. A single non-fatal failure (e.g. a package
# already at latest, or a peer not yet booted) must not abort the rest of the
# configuration. Errors are handled explicitly instead.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        LAB_IP="10.10.10.10"
        PEER_IP="10.10.10.20"
        MGMT_IP="192.168.10.201"
        HOSTNAME_EXPECTED="lab-router-a"
        ;;
    b)
        LAB_IP="10.10.10.20"
        PEER_IP="10.10.10.10"
        MGMT_IP="192.168.10.202"
        HOSTNAME_EXPECTED="lab-router-b"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>" >&2
        exit 2
        ;;
esac

LAB_CIDR=24
LAB_NET="10.10.10.0/24"
LAB_IF="eth1"
MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
FAE_USER="fae"
FAE_PASS="faelab123"          # documented lab fallback password (throwaway lab only)
IFACE_FILE="/etc/network/interfaces.d/${LAB_IF}"
TICKET_FILE="/root/FIELD_TICKET.txt"
FAULT_SCRIPT="/usr/local/sbin/lab-faults.sh"
FAULT_UNIT="lab-faults.service"
UNIT_PATH="/etc/systemd/system/${FAULT_UNIT}"
INTERFACES_MAIN="/etc/network/interfaces"

# Tracks non-fatal verification failures so the script can exit non-zero for any
# automation wrapping `pct exec ... setup.sh`.
VERIFY_FAILED=0

echo "=============================================================="
echo " lab1-broken-router setup :: role=${ROLE} (${HOSTNAME_EXPECTED})"
echo " mgmt=${MGMT_IP} (untouchable)   lab=${LAB_IP}/${LAB_CIDR} on ${LAB_IF}"
echo "=============================================================="

# =============================================================================
# 0. PRE-FLIGHT GUARD
#
#    setup.sh is the script that actually runs `ip addr flush dev eth1`, so it
#    must be at least as paranoid as break.sh before it mutates anything:
#
#      0a. The management lifeline must already be healthy. If it is not, we do
#          not know what state this container is in and must not touch it.
#      0b. eth1 must NOT be carrying the management address. If the CT's NICs
#          were built in the wrong order (net0/net1 swapped, or a bridge typo),
#          eth1 IS the lifeline and flushing it would lock the operator out.
#      0c. The hostname must match the role, which catches the easy slip of
#          running `setup.sh a` against CT 202.
#
#    All checks are read-only.
# =============================================================================
echo "[*] Pre-flight ..."

# 0a. Lifeline must be present and pointing out the management interface.
#     grep -F so the dots in the address are literal, not any-char wildcards.
PREFLIGHT_OK=1
ip -4 addr show dev "$MGMT_IF" 2>/dev/null | grep -qF "inet ${MGMT_IP}/" || PREFLIGHT_OK=0
ip -4 route show default 2>/dev/null | grep -qF "via ${MGMT_GW} dev ${MGMT_IF}" || PREFLIGHT_OK=0
if [ "$PREFLIGHT_OK" -ne 1 ]; then
    echo "" >&2
    echo "################################################################" >&2
    echo "#  FAIL - management lifeline is not healthy BEFORE any change  #" >&2
    echo "################################################################" >&2
    echo "  Expected: ${MGMT_IF} holds ${MGMT_IP}/24 and default via ${MGMT_GW} dev ${MGMT_IF}" >&2
    echo "  Actual:" >&2
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null | sed 's/^/    /' >&2
    ip -4 route show default 2>/dev/null | sed 's/^/    /' >&2
    echo "  Refusing to reconfigure ${LAB_IF} in an unknown state." >&2
    echo "  Check the CT config, then re-run. Role passed: '${ROLE}'." >&2
    exit 1
fi

# 0b. Refuse to flush eth1 if it is actually the lifeline (mis-mapped NICs).
if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -qF "inet ${MGMT_IP}/"; then
    echo "ERROR: ${LAB_IF} holds the management address ${MGMT_IP}." >&2
    echo "       The CT's NICs appear to be mis-mapped. Refusing to flush ${LAB_IF}." >&2
    exit 1
fi
if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -qE "inet 192\.168\.10\."; then
    echo "ERROR: ${LAB_IF} carries a 192.168.10.x address - that is the management" >&2
    echo "       subnet, not the lab subnet. Refusing to flush ${LAB_IF}." >&2
    exit 1
fi

# 0c. Role / container cross-check. Warn rather than abort: a freshly created CT
#     may not have had its hostname set yet, and that alone is not dangerous.
CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_EXPECTED" ]; then
    echo "    WARNING: hostname is '${CURRENT_HOSTNAME}', expected '${HOSTNAME_EXPECTED}'"
    echo "             for role '${ROLE}'. Continuing - but confirm you targeted the"
    echo "             right container (role a = CT 201, role b = CT 202)."
else
    echo "    hostname ${CURRENT_HOSTNAME} matches role ${ROLE}"
fi
echo "    lifeline healthy, ${LAB_IF} is not the lifeline - proceeding"

# =============================================================================
# 1. Wait for network before apt
#    Fresh LXC containers need a moment to acquire/settle their address; an
#    immediate `apt-get update` otherwise fails on DNS. Probe the MGMT gateway.
# =============================================================================
echo "[*] Waiting for management network ..."
NET_UP=0
for i in $(seq 1 15); do
    if ping -c1 -W1 "$MGMT_GW" >/dev/null 2>&1; then
        NET_UP=1
        echo "    network up after $((i)) attempt(s)"
        break
    fi
    sleep 2
done
[ "$NET_UP" -eq 1 ] || echo "    WARNING: ${MGMT_GW} not answering; continuing anyway"

# =============================================================================
# 2. Locale - suppress the Debian LXC 'Setting locale failed' spam
# =============================================================================
echo "[*] Configuring locale ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq locales >/dev/null 2>&1
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen >/dev/null 2>&1
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# =============================================================================
# 3. Packages - the diagnostic toolkit the learner will need
#    (each one maps to a discovery path for one of the injected faults)
# =============================================================================
echo "[*] Installing packages ..."
PKGS="curl iproute2 iputils-ping tcpdump net-tools openssh-server traceroute mtr-tiny sudo"
if ! apt-get install -y -qq $PKGS >/dev/null 2>&1; then
    echo "    first attempt failed, retrying after apt-get update ..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq $PKGS >/dev/null 2>&1 || echo "    WARNING: some packages may be missing"
fi

# =============================================================================
# 4. FAE user - the account the learner logs in as
# =============================================================================
echo "[*] Ensuring user '${FAE_USER}' ..."
if id "$FAE_USER" >/dev/null 2>&1; then
    echo "    user already exists"
else
    useradd -m -s /bin/bash "$FAE_USER" && echo "    user created"
fi
usermod -aG sudo "$FAE_USER" 2>/dev/null || true

# Documented fallback password for both accounts (lab-only credential).
# DELIBERATELY NO ROOT PASSWORD. sshd runs PermitRootLogin prohibit-password so
# it would never work over SSH anyway, and these CTs sit at 192.168.10.201-205 —
# a range whitelisted to the Kali VLAN and reachable across the whole tailnet.
# Root console access remains available from the Proxmox host: pct enter <CTID>
echo "${FAE_USER}:${FAE_PASS}" | chpasswd 2>/dev/null || echo "    WARNING: could not set ${FAE_USER} password"

# Seed the fae user's authorized_keys from root's, IF root has any. This lets the
# same workstation key that reaches root reach fae, without inventing a key.
if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$FAE_USER" -g "$FAE_USER" "/home/${FAE_USER}/.ssh"
    install -m 600 -o "$FAE_USER" -g "$FAE_USER" \
        /root/.ssh/authorized_keys "/home/${FAE_USER}/.ssh/authorized_keys"
    echo "    authorized_keys seeded from /root/.ssh/authorized_keys"
else
    echo "    no /root/.ssh/authorized_keys to seed (password fallback available)"
fi

# =============================================================================
# 5. SSH - port 22 only.
#    NOTE: Debian 12 uses ssh.socket socket-activation, which ignores the Port
#    directive in sshd_config. That only bites when you move off port 22, so we
#    deliberately do NOT change the port and no socket override is needed.
# =============================================================================
echo "[*] Enabling ssh ..."
systemctl enable --now ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1
systemctl is-active --quiet ssh || echo "    WARNING: ssh not active"

# =============================================================================
# 6. RESET - strip anything break.sh may have left behind.
#
#    This runs BEFORE eth1 is reconfigured, so the interface is rebuilt on a
#    clean slate rather than having leftovers deleted around it.
#
#    All operations are scoped to eth1 / the lab prefix. Nothing here can affect
#    eth0 or the default route.
# =============================================================================
echo "[*] Clearing any previously injected lab faults ..."

# 6-v2. Clear v2-era residue FIRST (nftables/iptables ICMP drop, strict rp_filter
#       + policy-routing table 100, tc qdisc, and the v2 persistence unit).
#       setup.sh doubles as the reset tool, so it must know how to undo whichever
#       fault generation was last armed — not just v1's. Everything here is
#       idempotent and scoped to eth1 / the lab subnet; nothing touches eth0.
systemctl disable --now lab-faults-v2.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/lab-faults-v2.service /usr/local/sbin/lab-faults-v2.sh
systemctl daemon-reload >/dev/null 2>&1 || true

# Fault 1 residue: the dedicated nft table, or the iptables fallback chain.
if command -v nft >/dev/null 2>&1; then
    nft delete table inet plant_filter >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -j PLANT_FILTER >/dev/null 2>&1 || true
    iptables -F PLANT_FILTER >/dev/null 2>&1 || true
    iptables -X PLANT_FILTER >/dev/null 2>&1 || true
fi

# Fault 2 residue: sysctl drop-ins (both the decoy and the one that actually
# wins), the ip rule, and policy table 100.
rm -f /etc/sysctl.d/60-plant-net.conf /etc/sysctl.d/99-zz-plant-hardening.conf
sysctl -w net.ipv4.conf.all.rp_filter=0        >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.eth1.rp_filter=0       >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.eth1.log_martians=0    >/dev/null 2>&1 || true
while ip rule del pref 100 >/dev/null 2>&1; do :; done
ip route flush table 100 >/dev/null 2>&1 || true

# Fault 3 residue: the egress qdisc on the LAB interface only. Never eth0.
tc qdisc del dev eth1 root >/dev/null 2>&1 || true
# v2 fault 2 now marks packets with nft (iptables is not installed in these CTs)
# and keys the policy rule on the mark, so the mark table must go too.
if command -v nft >/dev/null 2>&1; then
    nft delete table ip lab_mangle >/dev/null 2>&1 || true
fi
sysctl -w net.ipv4.conf.all.src_valid_mark=0  >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.eth1.src_valid_mark=0 >/dev/null 2>&1 || true
echo "    cleared v2 residue (nft filter+mangle, rp_filter, src_valid_mark, table 100, tc qdisc)"


# 6a. Remove the persistence unit from a prior break.sh run.
#     Unconditional - disable/rm/daemon-reload are all idempotent, and gating on
#     a `list-unit-files | grep` probe risks leaving a stale unit behind if the
#     probe misses (e.g. systemd not fully up in a freshly started CT).
systemctl disable --now "$FAULT_UNIT" >/dev/null 2>&1 || true
if [ -f "/etc/systemd/system/${FAULT_UNIT}" ]; then
    rm -f "/etc/systemd/system/${FAULT_UNIT}"
    echo "    removed ${FAULT_UNIT}"
fi
systemctl daemon-reload >/dev/null 2>&1 || true
rm -f "$FAULT_SCRIPT"

# 6b. Remove every VIA route that targets the lab segment (the bogus next-hop
#     fault, which break.sh installs as both a /24 and a /32).
#
#     CAUTION 1: a bare `ip route del 10.10.10.0/24` is ambiguous - the kernel's
#     own connected route for eth1 has the exact same prefix, so a bare delete
#     can remove the legitimate connected route instead of the fault. Every
#     delete below therefore names `via <gw> dev <if>` explicitly, which a
#     connected route (which has no `via`) can never match.
#
#     CAUTION 2: `ip route show 10.10.10.0/24` is an EXACT-prefix filter and
#     will not show a 10.10.10.10/32 route. We therefore scan the whole main
#     table and select on the 10.10.10. destination prefix. Default routes are
#     printed as `default ...` and can never match `^10\.10\.10\.`, so this scan
#     is structurally incapable of touching the lifeline.
ip route show 2>/dev/null | grep -E '^10\.10\.10\.' | grep -- ' via ' \
  | awk '{ g=""; d="";
           for (i=1;i<=NF;i++) { if ($i=="via") g=$(i+1); if ($i=="dev") d=$(i+1) }
           if (g!="" && d!="") print $1, g, d }' \
  | while read -r dst gw dev; do
        if ip route del "$dst" via "$gw" dev "$dev" 2>/dev/null; then
            echo "    deleted stale route ${dst} via ${gw} dev ${dev}"
        else
            echo "    WARNING: could not delete ${dst} via ${gw} dev ${dev}"
        fi
    done

# 6c. Remove permanent/static ARP entries on eth1 (the poisoned ARP fault).
#     NOTE: this `while read` runs in a subshell because it is on the right-hand
#     side of a pipe. That is intentional and correct here - the loop only calls
#     `ip neigh del` and `echo`, and no variable needs to survive the subshell.
#     Do not "fix" it into a process-substitution form without checking that.
ip -4 neigh show dev "$LAB_IF" 2>/dev/null | awk '/PERMANENT|permanent/ {print $1}' \
  | while read -r stale; do
        [ -n "$stale" ] && ip neigh del "$stale" dev "$LAB_IF" 2>/dev/null \
            && echo "    deleted permanent neigh entry ${stale}"
    done

# =============================================================================
# 7. LAB interface (eth1) -> correct WORKING values
#
#    Scoped strictly to eth1. `ip addr flush dev eth1` only clears eth1; eth0 and
#    the default route are never named here and are therefore untouched.
#    No gateway line is written for eth1 by design - the LAB segment is isolated.
# =============================================================================
echo "[*] Configuring ${LAB_IF} -> ${LAB_IP}/${LAB_CIDR} ..."

# --- ifupdown persistence, carefully ----------------------------------------
# This is the single highest-risk write in the script, because a malformed
# ifupdown config is a WHOLE-CONFIG parse failure, not a per-interface one:
# if `ifup -a` aborts, eth0 never gets its address at boot and the operator is
# locked out with console-only recovery. The ticket explicitly tells the learner
# to reboot, so this path WILL be exercised. Three protections:
#
#   1. Refuse to write if `pct` already declared eth1 in /etc/network/interfaces
#      (a duplicate `iface` stanza is a fatal parse error).
#   2. Ensure the main file actually sources interfaces.d/, or our file is
#      silently ignored and the lab quietly fails its own reboot test.
#   3. Validate after writing, and roll the file back if validation fails.
mkdir -p /etc/network/interfaces.d

# 7.1 - who owns the eth1 stanza?
#
# PVE's Debian LXC setup plugin REWRITES /etc/network/interfaces on EVERY
# container start, emitting a stanza per configured NIC. deploy.sh creates net1
# with an address, so a pre-existing `iface eth1` stanza is the NORMAL case, not
# an error. An earlier version aborted here — which made lab1 undeployable every
# single time. A duplicate `iface` stanza IS a fatal whole-config parse error
# (and would take eth0 down with it), so the correct response is simply not to
# write one: skip interfaces.d entirely and let break.sh's systemd persistence
# unit own eth1's state. That unit is already the source of truth for the
# faulted address, and it orders after networking.service. (C2)
SKIP_IFACE_FILE=0
if [ -f "$INTERFACES_MAIN" ] && grep -qE "^[[:space:]]*iface[[:space:]]+${LAB_IF}[[:space:]]+inet" "$INTERFACES_MAIN"; then
    echo "    ${INTERFACES_MAIN} already declares ${LAB_IF} (PVE-managed)"
    echo "    -> skipping ${IFACE_FILE}; eth1 state is owned by the persistence unit"
    rm -f "$IFACE_FILE"   # drop a stanza an older run may have left behind
    SKIP_IFACE_FILE=1
fi

if [ "$SKIP_IFACE_FILE" -eq 1 ]; then
    echo "    (declarative eth1 config skipped by design)"
else

# 7.2 - make sure interfaces.d is actually sourced
if [ -f "$INTERFACES_MAIN" ]; then
    if ! grep -qE '^[[:space:]]*source(-directory)?[[:space:]]' "$INTERFACES_MAIN"; then
        printf '\n# added by lab1-broken-router setup.sh\nsource /etc/network/interfaces.d/*\n' \
            >> "$INTERFACES_MAIN"
        echo "    added 'source /etc/network/interfaces.d/*' to ${INTERFACES_MAIN}"
    fi
else
    printf 'auto lo\niface lo inet loopback\n\nsource /etc/network/interfaces.d/*\n' \
        > "$INTERFACES_MAIN"
    echo "    created a minimal ${INTERFACES_MAIN}"
fi

# 7.3 - write, then validate, then roll back on failure
# The backup MUST NOT live in interfaces.d/ — that directory is sourced by an
# unfiltered glob, so a file named eth1.bak.1234 is parsed as config and creates
# the exact duplicate-stanza parse failure this block exists to prevent. If the
# script were interrupted between the cp and the rm, the stray file would make
# `ifup -a` abort on the next reboot and eth0 would never get its address —
# locking the learner out. Keep it outside the glob, and trap-clean it. (C3)
IFACE_BACKUP=""
if [ -f "$IFACE_FILE" ]; then
    IFACE_BACKUP="$(mktemp /var/tmp/lab1-eth1.XXXXXX 2>/dev/null)" || IFACE_BACKUP=""
    if [ -n "$IFACE_BACKUP" ]; then
        cp -p "$IFACE_FILE" "$IFACE_BACKUP"
        trap 'rm -f "${IFACE_BACKUP:-/dev/null}"' EXIT
    fi
fi

cat > "$IFACE_FILE" << EOF
# lab1-broken-router :: LAB segment interface (managed by setup.sh)
# Isolated 10.10.10.0/24 process segment. NO gateway on purpose.
# Do not add a gateway line here - it would create a default route and would
# violate the lab's management-lifeline invariant.
auto ${LAB_IF}
iface ${LAB_IF} inet static
    address ${LAB_IP}
    netmask 255.255.255.0
EOF

# ifquery parses the entire ifupdown config. A non-zero exit, or a listing that
# has lost ${MGMT_IF}, means we just broke boot-time networking - undo it now.
IFACE_VALID=1
if command -v ifquery >/dev/null 2>&1; then
    if ! IFQ_OUT="$(ifquery --list --allow=auto 2>&1)"; then
        IFACE_VALID=0
    elif ! printf '%s\n' "$IFQ_OUT" | grep -qx "$MGMT_IF"; then
        IFACE_VALID=0
    fi
else
    echo "    NOTE: ifquery unavailable - config written without validation"
fi

if [ "$IFACE_VALID" -ne 1 ]; then
    echo "ERROR: writing ${IFACE_FILE} broke the ifupdown config." >&2
    echo "       Rolling back so ${MGMT_IF} still comes up on reboot." >&2
    if [ -n "$IFACE_BACKUP" ]; then
        mv -f "$IFACE_BACKUP" "$IFACE_FILE"
    else
        rm -f "$IFACE_FILE"
    fi
    echo "       ifquery output was:" >&2
    printf '%s\n' "${IFQ_OUT:-<none>}" | sed 's/^/         /' >&2
    exit 1
fi
[ -n "$IFACE_BACKUP" ] && rm -f "$IFACE_BACKUP"
trap - EXIT
echo "    ${IFACE_FILE} written and validated"

fi   # end SKIP_IFACE_FILE guard (7.2/7.3 only run when we own the stanza)

# Apply live, idempotently.
if ip link show "$LAB_IF" >/dev/null 2>&1; then
    ip link set "$LAB_IF" up 2>/dev/null || true
    ip addr flush dev "$LAB_IF" 2>/dev/null || true          # scoped: eth1 only
    ip addr add "${LAB_IP}/${LAB_CIDR}" dev "$LAB_IF" 2>/dev/null || true
    echo "    applied live"
else
    echo "    WARNING: ${LAB_IF} does not exist - check the CT's vmbr1 NIC"
fi

# Confirm the connected route came back (it is what the /24 address implies).
if ip route show "$LAB_NET" 2>/dev/null | grep -q "dev ${LAB_IF}"; then
    echo "    connected route for ${LAB_NET} present on ${LAB_IF}"
else
    echo "    WARNING: no connected route for ${LAB_NET} on ${LAB_IF}"
fi

# =============================================================================
# 8. Field ticket -> /root/FIELD_TICKET.txt and /etc/motd
#    Kept byte-identical to labs/lab1-broken-router/FIELD_TICKET.txt.
# =============================================================================
echo "[*] Installing field ticket ..."
cat > "$TICKET_FILE" << 'LAB_TICKET_EOF'
================================================================================
                 NORTHSTAR LOGISTICS - IT SERVICE DESK
                        FIELD DISPATCH TICKET
================================================================================

TICKET ID      : NSL-48812
OPENED         : 08:14 local
PRIORITY       : P2 - HIGH (site automation degraded, no data loss)
STATUS         : DISPATCHED - awaiting Field Application Engineer
QUEUE          : Network Operations -> Field Services
REPORTER       : Dana Whitfield, Plant Floor Supervisor - Building 4
CONTACT        : ext. 4471 / dwhitfield@northstar-logistics.example
ASSIGNED TO    : (you)

--------------------------------------------------------------------------------
AFFECTED SYSTEMS
--------------------------------------------------------------------------------
  Container-A   lab-router-a    LAB interface address 10.10.10.10
  Container-B   lab-router-b    LAB interface address 10.10.10.20

  Both hosts sit on the isolated 10.10.10.0/24 process segment that carries
  telemetry between the two line controllers. Nothing else lives on that
  segment.

--------------------------------------------------------------------------------
HOW TO CONNECT
--------------------------------------------------------------------------------
  Management access is UNAFFECTED and is confirmed working from the office
  network. Connect over the management addresses:

      ssh fae@192.168.10.201        (Container-A)
      ssh fae@192.168.10.202        (Container-B)

  Fallback console password is on file with the desk if key auth is not set up
  for your workstation. Do NOT reconfigure the management interface for any
  reason - it is the only remote path to these boxes and there is no one on
  site after 17:00 to reboot them.

--------------------------------------------------------------------------------
USER COMPLAINT (verbatim from reporter)
--------------------------------------------------------------------------------
  "Container A cannot ping Container B.

  This started sometime overnight. Yesterday afternoon the two boxes were
  talking to each other fine - I know because the line status board was
  updating. This morning the board is frozen on yesterday's numbers.

  When I get on Container A and ping 10.10.10.20 it just sits there and counts
  up, and at the end it tells me 100% packet loss. I think one of the times I
  tried it I got some kind of unreachable message back instead, but I was going
  back and forth between the two boxes all morning and I honestly could not tell
  you which one did which. Same story in the other direction from Container B to
  10.10.10.10 - nothing gets through either way.

  Both machines are powered on. I can log into both of them from my desk with
  no trouble at all, which is why I don't think this is a dead box or a dead
  cable. It is only the traffic between the two of them on the plant segment
  that is broken."

--------------------------------------------------------------------------------
SYMPTOMS OBSERVED / TRIAGE ALREADY PERFORMED BY REPORTER
--------------------------------------------------------------------------------
  * Ping from A to 10.10.10.20 -> 100% packet loss.
  * Ping from B to 10.10.10.10 -> 100% packet loss.
  * Reporter's account of whether an ICMP error was ever returned is
    inconsistent. Do not rely on it - re-test from both ends yourself and
    record what you actually see.
  * Both hosts remain fully reachable over management the entire time.
  * Reporter rebooted BOTH containers. No change - the problem came back
    exactly the same after the reboot.
  * Reporter confirmed the LAB interface shows as UP on both hosts.
  * Reporter re-seated the virtual NIC assignment in the hypervisor UI. No
    change.
  * No known change window last night. No one admits to touching either box.
    (Treat that claim with the usual amount of trust.)

--------------------------------------------------------------------------------
SCOPE OF WORK
--------------------------------------------------------------------------------
  1. Restore bidirectional ICMP reachability between 10.10.10.10 and
     10.10.10.20.
  2. Verify the fix survives a reboot of both containers.
  3. Document root cause and the exact commands used, for the change record.

  OUT OF SCOPE / HARD CONSTRAINT: the management interface, its address, and
  the default route must not be modified. If you lose management connectivity
  the ticket becomes a truck roll and the line stays down until tomorrow.

--------------------------------------------------------------------------------
NOTES
--------------------------------------------------------------------------------
  Assume the problem may be more than one thing. The reporter is not a network
  person and their description reflects what they could see from the surface.
  Work the layers in order and re-test after every change.

================================================================================
                        END OF TICKET  -  NSL-48812
================================================================================
LAB_TICKET_EOF

chmod 644 "$TICKET_FILE"
cp "$TICKET_FILE" /etc/motd
chmod 644 /etc/motd

# =============================================================================
# 9. Peer reachability check (working state should pass once BOTH sides are set up)
# =============================================================================
echo "[*] Testing LAB reachability to peer ${PEER_IP} ..."
PEER_OK=0
for i in $(seq 1 5); do
    if ping -c1 -W1 -I "$LAB_IF" "$PEER_IP" >/dev/null 2>&1; then
        PEER_OK=1
        break
    fi
    sleep 1
done
if [ "$PEER_OK" -eq 1 ]; then
    echo "    peer ${PEER_IP} reachable"
else
    echo "    peer ${PEER_IP} NOT reachable yet (expected if the other CT is not set up)"
fi

# =============================================================================
# 10. Verification
# =============================================================================
echo ""
echo "=== Verification ==="

# ok <msg> / bad <msg> - bad() also trips VERIFY_FAILED so the script can exit
# non-zero for any automation wrapping `pct exec ... setup.sh`.
ok()  { echo "[OK]   $*"; }
bad() { echo "[FAIL] $*"; VERIFY_FAILED=1; }

MISSING=""
for p in curl tcpdump ping traceroute mtr netstat sudo; do
    command -v "$p" >/dev/null 2>&1 || MISSING="${MISSING} ${p}"
done
if [ -z "$MISSING" ]; then
    ok "packages installed"
else
    bad "packages missing:${MISSING}"
fi

if systemctl is-active --quiet ssh; then
    ok "ssh active"
else
    bad "ssh not active"
fi

if id "$FAE_USER" >/dev/null 2>&1; then
    ok "user ${FAE_USER} exists"
else
    bad "user ${FAE_USER} missing"
fi

if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -qE "inet ${LAB_IP//./\\.}/${LAB_CIDR}([^0-9]|$)"; then
    ok "${LAB_IF} address is ${LAB_IP}/${LAB_CIDR}"
else
    bad "${LAB_IF} address is not ${LAB_IP}/${LAB_CIDR}"
    ip -4 addr show dev "$LAB_IF" 2>/dev/null | sed 's/^/       /'
fi

if [ -s "$TICKET_FILE" ]; then
    ok "ticket present at ${TICKET_FILE}"
else
    bad "ticket missing at ${TICKET_FILE}"
fi

if [ -s /etc/motd ]; then
    ok "ticket installed as /etc/motd"
else
    bad "/etc/motd not installed"
fi

# Peer reachability is NOT counted as a verification failure: on the first
# container it legitimately fails until the second one is set up. It is reported
# but does not affect the exit code.
if [ "$PEER_OK" -eq 1 ]; then
    ok "LAB peer ${PEER_IP} reachable"
else
    echo "[WARN] LAB peer ${PEER_IP} unreachable - expected if the other CT is not"
    echo "       set up yet. Re-run this script on both, then re-check."
fi

# No fault residue: the path to the peer must be the plain connected route on
# eth1, not a via-route through some other next-hop.
if ip route get "$PEER_IP" 2>/dev/null | grep -q "dev ${LAB_IF}" \
   && ! ip route get "$PEER_IP" 2>/dev/null | grep -q " via "; then
    ok "path to ${PEER_IP} is connected via ${LAB_IF} (no fault residue)"
else
    bad "path to ${PEER_IP} is not a clean connected route:"
    ip route get "$PEER_IP" 2>/dev/null | sed 's/^/       /'
fi

if ip -4 neigh show dev "$LAB_IF" 2>/dev/null | grep -qi "PERMANENT"; then
    bad "permanent ARP entries still present on ${LAB_IF}:"
    ip -4 neigh show dev "$LAB_IF" 2>/dev/null | grep -i "PERMANENT" | sed 's/^/       /'
else
    ok "no permanent ARP entries on ${LAB_IF}"
fi

if [ -e "$UNIT_PATH" ] || [ -e "$FAULT_SCRIPT" ]; then
    bad "fault persistence artifacts still present"
else
    ok "fault persistence removed"
fi

# Sanity: confirm we did not disturb the lifeline. setup.sh never writes to eth0
# or the default route, so this is a canary, not a fix-up.
# grep -F for the address (literal dots) and a 'via <gw> dev <mgmt_if>' match so
# a default route out of some other interface cannot silently pass.
if ip -4 addr show dev "$MGMT_IF" 2>/dev/null | grep -qF "inet ${MGMT_IP}/" \
   && ip -4 route show default 2>/dev/null | grep -qF "via ${MGMT_GW} dev ${MGMT_IF}"; then
    ok "mgmt lifeline intact (${MGMT_IF} ${MGMT_IP}, default via ${MGMT_GW})"
else
    bad "mgmt lifeline NOT as expected - investigate before proceeding"
fi

echo ""
if [ "$VERIFY_FAILED" -eq 0 ]; then
    echo "Setup complete for role '${ROLE}'. Baseline is the WORKING state."
    echo "Run break.sh <role> on each container to inject the lab faults."
    exit 0
else
    echo "Setup for role '${ROLE}' finished with FAILURES (see [FAIL] above)."
    echo "Do not arm the lab until they are resolved."
    exit 1
fi
