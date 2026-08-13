#!/bin/bash
# =============================================================================
# lab2-tunnel-failure :: setup.sh
# -----------------------------------------------------------------------------
# Builds the WORKING baseline state for the "Tunnel Failure" networking lab:
# a genuinely functional site-to-site OpenVPN tunnel between two Debian 12
# privileged LXC containers.
#
# Runs INSIDE the container as root, e.g.:
#     pct push 203 setup.sh /root/setup.sh && pct exec 203 -- bash /root/setup.sh a
#     pct push 204 setup.sh /root/setup.sh && pct exec 204 -- bash /root/setup.sh b
#
# Usage: setup.sh <role>       role = a (VPN server) | b (VPN client)
#
# TOPOLOGY (fixed, do not change):
#   CT 203 lab-vpn-a : eth0 192.168.10.203/24 gw 192.168.10.1 (vmbr0, MGMT)
#                      eth1 10.20.20.10/24     no gateway      (vmbr2, LAB)
#                      OpenVPN SERVER, tunnel address 10.99.99.1
#   CT 204 lab-vpn-b : eth0 192.168.10.204/24 gw 192.168.10.1 (vmbr0, MGMT)
#                      eth1 10.20.20.20/24     no gateway      (vmbr2, LAB)
#                      OpenVPN CLIENT, tunnel address 10.99.99.2
#
#   Tunnel transport : UDP/1194 across the eth1 (10.20.20.0/24) segment.
#   Tunnel subnet    : 10.99.99.0/24
#
#   SITE LANs (the "office networks" the ticket talks about). Both eth1 IPs sit
#   on the SAME /24, so there is no far-side subnet to route to unless we model
#   one. Each gateway therefore gets a small simulated site LAN behind it, built
#   from a veth pair into a network namespace:
#       Site-A LAN 172.16.10.0/24  gateway 172.16.10.1  host 172.16.10.100 (ns site-a)
#       Site-B LAN 172.16.20.0/24  gateway 172.16.20.1  host 172.16.20.100 (ns site-b)
#   This is what makes the lab honest: traffic from a site host to the far site
#   is genuinely FORWARDED by the gateway (tun0 <-> LAN side), so an ip_forward
#   fault actually bites instead of merely looking wrong in sysctl output.
#
# *** SACRED INVARIANT ***
#   eth0, its IP, and the default route via 192.168.10.1 are the learner's SSH
#   lifeline over Tailscale. NOTHING in this script may touch them. Every write
#   below is scoped explicitly to eth1, tun0, the simulated site LANs, or the
#   10.20.20.0/24 and 10.99.99.0/24 prefixes.
#
#   In particular: the OpenVPN client uses `route-nopull` and there is NO
#   `redirect-gateway` anywhere. An OpenVPN-pushed default route would replace
#   the learner's default route and sever SSH. There is no bare
#   `ip route add default` / `ip route del default` in this repo, and there
#   must never be one.
#
# KEY DISTRIBUTION CONTRACT (the HOST deploy script owns this):
#   Role `a` GENERATES /etc/openvpn/static.key.
#   Role `b` CONSUMES /etc/openvpn/static.key and will refuse to continue if it
#   is absent. The host is responsible for the copy in between:
#       pct exec 203 -- bash /root/setup.sh a
#       pct pull 203 /etc/openvpn/static.key /tmp/lab2-static.key
#       pct push 204 /tmp/lab2-static.key /etc/openvpn/static.key
#       pct exec 204 -- chmod 600 /etc/openvpn/static.key
#       pct exec 204 -- bash /root/setup.sh b
#
# This script is also the RESET tool: re-running it after break.sh removes every
# injected fault and returns the container to the known-good state.
#
# set -e is deliberately NOT used. A single non-fatal failure (a package already
# at latest, a peer not yet booted) must not abort the rest of the run. Errors
# are handled explicitly instead.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        LAB_IP="10.20.20.10"
        PEER_LAB_IP="10.20.20.20"
        MGMT_IP="192.168.10.203"
        HOSTNAME_EXPECTED="lab-vpn-a"
        VPN_ROLE="server"                  # -> /etc/openvpn/server.conf, openvpn@server
        TUN_LOCAL="10.99.99.1"
        TUN_REMOTE="10.99.99.2"
        SITE_LAN="172.16.10.0/24"
        SITE_GW_IP="172.16.10.1"
        SITE_HOST_IP="172.16.10.100"
        SITE_NS="site-a"
        FAR_LAN="172.16.20.0"
        FAR_LAN_MASK="255.255.255.0"
        FAR_LAN_CIDR="172.16.20.0/24"
        FAR_HOST_IP="172.16.20.100"
        ;;
    b)
        LAB_IP="10.20.20.20"
        PEER_LAB_IP="10.20.20.10"
        MGMT_IP="192.168.10.204"
        HOSTNAME_EXPECTED="lab-vpn-b"
        VPN_ROLE="client"                  # -> /etc/openvpn/client.conf, openvpn@client
        TUN_LOCAL="10.99.99.2"
        TUN_REMOTE="10.99.99.1"
        SITE_LAN="172.16.20.0/24"
        SITE_GW_IP="172.16.20.1"
        SITE_HOST_IP="172.16.20.100"
        SITE_NS="site-b"
        FAR_LAN="172.16.10.0"
        FAR_LAN_MASK="255.255.255.0"
        FAR_LAN_CIDR="172.16.10.0/24"
        FAR_HOST_IP="172.16.10.100"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>" >&2
        exit 2
        ;;
esac

LAB_IF="eth1"
LAB_CIDR=24
MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
FAE_USER="fae"
FAE_PASS="faelab123"          # documented lab fallback password (throwaway lab only)

IFACE_FILE="/etc/network/interfaces.d/${LAB_IF}"
TICKET_FILE="/root/FIELD_TICKET.txt"

OVPN_DIR="/etc/openvpn"
OVPN_KEY="${OVPN_DIR}/static.key"
OVPN_CONF="${OVPN_DIR}/${VPN_ROLE}.conf"
OVPN_UNIT="openvpn@${VPN_ROLE}"

LAB_STATE_DIR="/etc/lab-vpn"           # small state dir the netprep unit reads
MTU_FILE="${LAB_STATE_DIR}/eth1.mtu"   # break.sh rewrites this to persist the MTU fault
NETPREP_SCRIPT="/usr/local/sbin/lab-netprep.sh"
NETPREP_UNIT="lab-netprep.service"
FAULT_SYSCTL="/etc/sysctl.d/99-zz-lab-tuning.conf"   # written ONLY by break.sh
BASE_SYSCTL="/etc/sysctl.d/99-lab-vpn.conf"          # written by setup.sh (working state)

# Working-state MTU numbers.
#   1500 on the underlay leaves headroom; 1300 inside the tunnel keeps the
#   encapsulated packet comfortably under it, so large payloads pass cleanly.
#   break.sh inverts exactly this relationship.
GOOD_UNDERLAY_MTU=1500
GOOD_TUN_MTU=1300
GOOD_MSSFIX=1250

echo "=============================================================="
echo " lab2-tunnel-failure setup :: role=${ROLE} (${HOSTNAME_EXPECTED})"
echo " mgmt=${MGMT_IP} (untouchable)   lab=${LAB_IP}/${LAB_CIDR} on ${LAB_IF}"
echo " vpn=${VPN_ROLE}  tunnel ${TUN_LOCAL} <-> ${TUN_REMOTE}"
echo " site LAN=${SITE_LAN} (host ${SITE_HOST_IP})  far LAN=${FAR_LAN_CIDR}"
echo "=============================================================="

# =============================================================================
# 1. Wait for network before apt
#    Fresh LXC containers need a moment to settle their addressing; an immediate
#    `apt-get update` otherwise fails on DNS. Probe the MGMT gateway.
# =============================================================================
echo "[*] Waiting for management network ..."
NET_UP=0
for i in $(seq 1 15); do
    if ping -c1 -W1 "$MGMT_GW" >/dev/null 2>&1; then
        NET_UP=1
        echo "    network up after ${i} attempt(s)"
        break
    fi
    sleep 2
done
[ "$NET_UP" -eq 1 ] || echo "    WARNING: ${MGMT_GW} not answering; continuing anyway"

# =============================================================================
# 1b. IDENTITY ASSERTION - am I actually on the container this role refers to?
#
# The two deploy command lines differ by a handful of characters (203/204,
# a/b), so a copy-paste slip is the single most likely operator error in this
# lab. Without this check, `setup.sh a` on CT 204 would happily reconfigure the
# wrong box's eth1 and VPN role.
#
# Fail fast, before anything is written. Note this only READS eth0.
# =============================================================================
if ! grep -qF "inet ${MGMT_IP}/" <<< "$(ip -4 addr show dev "$MGMT_IF" 2>/dev/null)"; then
    echo "" >&2
    echo "ERROR: role '${ROLE}' expects ${MGMT_IP} on ${MGMT_IF}, but this container" >&2
    echo "       does not have that address. This looks like the WRONG CONTAINER." >&2
    echo "       Expected: ${HOSTNAME_EXPECTED} (${MGMT_IP})" >&2
    echo "       Actual ${MGMT_IF} addressing:" >&2
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null | sed 's/^/         /' >&2
    echo "       Nothing was changed. Re-check the CTID / role pairing:" >&2
    echo "         CT 203 -> role a      CT 204 -> role b" >&2
    exit 2
fi

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
#    Each maps to a discovery path for one of the injected faults:
#      sysctl/procps -> forwarding fault    iproute2 -> routing fault
#      iputils/tracepath -> MTU fault       tcpdump -> proving the data plane
# =============================================================================
echo "[*] Installing packages ..."
PKGS="openvpn openssl curl iproute2 iputils-ping iputils-tracepath \
tcpdump net-tools traceroute mtr-tiny openssh-server sudo procps"
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
#    Debian 12 uses ssh.socket socket-activation, which ignores the Port
#    directive in sshd_config. That only bites when you move off port 22, so we
#    deliberately do NOT change the port and no socket override is needed.
# =============================================================================
echo "[*] Enabling ssh ..."
systemctl enable --now ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1
systemctl is-active --quiet ssh || echo "    WARNING: ssh not active"

# =============================================================================
# 6. LAB interface (eth1) + simulated site LAN -> correct WORKING values
#
#    All of this is applied by ONE idempotent script, /usr/local/sbin/lab-netprep.sh,
#    which is also wired to a systemd oneshot unit. Doing it this way means the
#    live state and the boot-time state come from a single source of truth, so
#    "does the fix survive a reboot?" is a meaningful question in this lab.
#
#    Scoped strictly to eth1 / the site LAN. eth0 and the default route are never
#    named by the netprep script.
# =============================================================================
echo "[*] Writing lab network state ..."
mkdir -p "$LAB_STATE_DIR"
echo "$ROLE" > "${LAB_STATE_DIR}/role"
echo "$GOOD_UNDERLAY_MTU" > "$MTU_FILE"      # break.sh rewrites this file, not the script

# A declarative record of eth1 for anyone reading /etc/network/interfaces.d.
#
# *** LIFELINE-ADJACENT HAZARD - read before changing this block ***
# Proxmox's Debian LXC setup plugin rewrites the container's
# /etc/network/interfaces on every container START, with a stanza for every
# configured NIC - eth1 included. If that file also sources interfaces.d, then
# at boot `ifup -a` parses BOTH declarations. Classic ifupdown treats a
# duplicate `iface` declaration as a PARSE ERROR and aborts the whole run -
# it does not skip the offending stanza and carry on. eth0's address in a PVE
# Debian CT is configured by that very same `ifup -a`, so a duplicate eth1
# stanza can take eth0 down with it at the next reboot.
#
# The ticket explicitly tells the candidate to reboot and re-verify, so this is
# not a theoretical path - the lab drives the operator straight into it.
#
# Therefore: write this file ONLY if nothing already declares eth1. When
# Proxmox owns the stanza we skip it entirely and lab-netprep.service remains
# the single source of truth for eth1 (which it is in every case anyway - it is
# the thing that actually runs).
mkdir -p /etc/network/interfaces.d
if grep -qE '^[[:space:]]*iface[[:space:]]+eth1([[:space:]]|$)' /etc/network/interfaces 2>/dev/null; then
    echo "    /etc/network/interfaces already declares ${LAB_IF}; skipping ${IFACE_FILE}"
    echo "    (lab-netprep.service is the source of truth for ${LAB_IF} either way)"
    rm -f "$IFACE_FILE"          # remove a stanza a previous run may have left
else
# The stanza is only meaningful if the main file actually sources this directory.
# Without it our file is silently ignored, and the declarative eth1 record that
# break.sh edits for the learner to discover would never be read. (D11)
if [ -f /etc/network/interfaces ] && ! grep -qE '^[[:space:]]*source(-directory)?[[:space:]]' /etc/network/interfaces 2>/dev/null; then
    printf '
# added by lab2-tunnel-failure setup.sh
source /etc/network/interfaces.d/*
' >> /etc/network/interfaces
    echo "    added 'source /etc/network/interfaces.d/*' to /etc/network/interfaces"
fi
cat > "$IFACE_FILE" << EOF
# lab2-tunnel-failure :: LAB / VPN carrier interface (managed by setup.sh)
# Isolated 10.20.20.0/24 inter-site carrier segment. NO gateway on purpose.
# Do not add a gateway line here - it would create a default route and would
# violate the lab's management-lifeline invariant.
auto ${LAB_IF}
iface ${LAB_IF} inet static
    address ${LAB_IP}
    netmask 255.255.255.0
    mtu ${GOOD_UNDERLAY_MTU}
EOF
fi

cat > "$NETPREP_SCRIPT" << 'NETPREP_EOF'
#!/bin/bash
# =============================================================================
# lab-netprep.sh  (generated by lab2-tunnel-failure/setup.sh - do not hand-edit)
# -----------------------------------------------------------------------------
# Idempotently brings up, on every boot and on demand:
#   * eth1 (the 10.20.20.0/24 VPN carrier segment) with its address and MTU
#   * the simulated site LAN behind this gateway (veth pair into a netns)
#
# The eth1 MTU is read from /etc/lab-vpn/eth1.mtu so it can be changed
# (by setup.sh or break.sh) without rewriting this script.
#
# *** This script must never reference eth0 or the default route. ***
# The only default route it creates lives INSIDE the site network namespace and
# points at the gateway's own site LAN address. It cannot reach the host
# routing table.
# =============================================================================
set -uo pipefail

ROLE="$(cat /etc/lab-vpn/role 2>/dev/null)"
MTU="$(cat /etc/lab-vpn/eth1.mtu 2>/dev/null)"
[ -n "$MTU" ] || MTU=1500

case "$ROLE" in
    a) LAB_IP="10.20.20.10"; NS="site-a"; GW_IP="172.16.10.1"; HOST_IP="172.16.10.100" ;;
    b) LAB_IP="10.20.20.20"; NS="site-b"; GW_IP="172.16.20.1"; HOST_IP="172.16.20.100" ;;
    *) echo "lab-netprep: unknown or missing role in /etc/lab-vpn/role" >&2; exit 2 ;;
esac

VETH_GW="lan-gw"       # gateway side of the veth pair
VETH_NS="lan0"         # namespace side of the veth pair

# --- eth1: address + MTU (scoped, never eth0) --------------------------------
if ip link show eth1 >/dev/null 2>&1; then
    ip link set eth1 up 2>/dev/null || true
    ip link set eth1 mtu "$MTU" 2>/dev/null || true
    # Only (re)write the address if it is not already exactly right - keeps this
    # safe to run repeatedly while the tunnel is live.
    if ! ip -4 addr show dev eth1 | grep -q "inet ${LAB_IP}/24\b"; then
        ip addr flush dev eth1 2>/dev/null || true      # scoped: eth1 only
        ip addr add "${LAB_IP}/24" dev eth1 2>/dev/null || true
    fi
else
    echo "lab-netprep: WARNING eth1 not present - check the CT's vmbr2 NIC" >&2
fi

# --- Simulated site LAN behind this gateway ----------------------------------
# A network namespace gives us a real host on the far side of a real forwarding
# decision. Without it, "ip_forward=0" would be invisible, because traffic the
# gateway originates itself is not forwarded traffic.
mkdir -p /var/run/netns
if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$NS"; then
    if ! ip netns add "$NS" 2>/dev/null; then
        echo "lab-netprep: WARNING could not create netns ${NS} (kernel/LXC restriction)." >&2
        echo "lab-netprep: falling back to a dummy interface for the site LAN address." >&2
        modprobe dummy 2>/dev/null || true
        ip link show site0 >/dev/null 2>&1 || ip link add site0 type dummy 2>/dev/null
        ip link set site0 up 2>/dev/null || true
        ip -4 addr show dev site0 2>/dev/null | grep -q "inet ${GW_IP}/24\b" \
            || ip addr add "${GW_IP}/24" dev site0 2>/dev/null || true
        exit 0
    fi
fi

# veth pair: create only if the gateway side is missing.
# If the namespace survived but lan-gw did not (or vice versa), `ip link add`
# fails because the peer already exists inside the ns. Both errors used to be
# swallowed by `|| true`, so the site LAN silently never came up and netprep
# still reported success. Tear down the stale half first, and report. (D14)
if ! ip link show "$VETH_GW" >/dev/null 2>&1; then
    ip netns exec "$NS" ip link del "$VETH_NS" 2>/dev/null || true
    if ! ip link add "$VETH_GW" type veth peer name "$VETH_NS" 2>/dev/null; then
        echo "    ERROR: could not create veth pair ${VETH_GW}/${VETH_NS}" >&2
        SITE_LAN_OK=0
    elif ! ip link set "$VETH_NS" netns "$NS" 2>/dev/null; then
        echo "    ERROR: could not move ${VETH_NS} into netns ${NS}" >&2
        SITE_LAN_OK=0
    fi
fi

ip link set "$VETH_GW" up 2>/dev/null || true
ip -4 addr show dev "$VETH_GW" 2>/dev/null | grep -q "inet ${GW_IP}/24\b" \
    || ip addr add "${GW_IP}/24" dev "$VETH_GW" 2>/dev/null || true

# Namespace side: address, loopback, and a default route that only exists
# INSIDE the namespace and points at this gateway's site LAN address.
ip netns exec "$NS" ip link set lo up 2>/dev/null || true
ip netns exec "$NS" ip link set "$VETH_NS" up 2>/dev/null || true
ip netns exec "$NS" sh -c "ip -4 addr show dev ${VETH_NS} | grep -q 'inet ${HOST_IP}/24' \
    || ip addr add ${HOST_IP}/24 dev ${VETH_NS}" 2>/dev/null || true
ip netns exec "$NS" sh -c "ip route show default | grep -q 'via ${GW_IP}' \
    || ip route add default via ${GW_IP}" 2>/dev/null || true

exit 0
NETPREP_EOF
chmod 755 "$NETPREP_SCRIPT"

cat > "/etc/systemd/system/${NETPREP_UNIT}" << EOF
[Unit]
Description=lab2-tunnel-failure :: LAB segment + simulated site LAN
After=network-online.target networking.service
Wants=network-online.target
# Ordered before OpenVPN so eth1 and the site LAN exist before the tunnel comes up.
Before=openvpn@server.service openvpn@client.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NETPREP_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "$NETPREP_UNIT" >/dev/null 2>&1 || true
systemctl restart "$NETPREP_UNIT" >/dev/null 2>&1 \
    || bash "$NETPREP_SCRIPT" || echo "    WARNING: netprep reported problems"
echo "    ${LAB_IF}=${LAB_IP}/${LAB_CIDR} mtu ${GOOD_UNDERLAY_MTU}, site LAN ${SITE_LAN} ready"

# =============================================================================
# 6b. RESET - strip anything a previous break.sh run left behind.
#     Every removal here is scoped to a lab-owned artefact. Nothing in this
#     block can affect eth0 or the default route.
# =============================================================================
echo "[*] Clearing any previously injected lab faults ..."

# Fault 1 persistence: the innocuously-named sysctl drop-in break.sh writes.
if [ -f "$FAULT_SYSCTL" ]; then
    rm -f "$FAULT_SYSCTL"
    echo "    removed ${FAULT_SYSCTL}"
fi

# Baseline forwarding: a site-to-site gateway must forward. Persist it, apply it.
cat > "$BASE_SYSCTL" << 'EOF'
# lab2-tunnel-failure :: baseline forwarding for a site-to-site gateway
net.ipv4.ip_forward = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true

# Fault 3 persistence: MTU is stored in one file, already reset above; re-apply
# live in case break.sh lowered it since the netprep run.
ip link set "$LAB_IF" mtu "$GOOD_UNDERLAY_MTU" 2>/dev/null || true

# Fault 2 persistence lives in the client config, which section 8 rewrites
# wholesale - nothing to strip here.

# =============================================================================
# 7. Static pre-shared key
#
#    Deliberately a STATIC KEY (point-to-point) deployment rather than a full
#    PKI. Two peers, one file, no CA lifecycle, no cert clock-skew failures -
#    dramatically more reliable to automate, and the lab is about the data
#    plane, not about X.509.
#
#    Role a mints the key. Role b must already have it (host deploy script
#    copies it). See the KEY DISTRIBUTION CONTRACT in the header.
# =============================================================================
mkdir -p "$OVPN_DIR"
if [ "$ROLE" = "a" ]; then
    if [ -s "$OVPN_KEY" ]; then
        echo "[*] Static key already present at ${OVPN_KEY} (reusing)"
    else
        echo "[*] Generating static key ${OVPN_KEY} ..."
        if ! openvpn --genkey secret "$OVPN_KEY" >/dev/null 2>&1; then
            # Pre-2.6 syntax fallback.
            openvpn --genkey --secret "$OVPN_KEY" >/dev/null 2>&1
        fi
    fi
    chmod 600 "$OVPN_KEY" 2>/dev/null || true
    if [ ! -s "$OVPN_KEY" ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "  FATAL: could not generate ${OVPN_KEY}" >&2
        echo "  Is the openvpn package installed? Check apt output above." >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        exit 3
    fi
else
    if [ ! -s "$OVPN_KEY" ]; then
        echo "" >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "  FATAL: missing static key at ${OVPN_KEY}" >&2
        echo "" >&2
        echo "  Role 'b' is the tunnel CLIENT and does NOT generate the key." >&2
        echo "  The HOST deploy script must copy it from role 'a' first:" >&2
        echo "" >&2
        echo "      pct exec 203 -- bash /root/setup.sh a" >&2
        echo "      pct pull 203 /etc/openvpn/static.key /tmp/lab2-static.key" >&2
        echo "      pct push 204 /tmp/lab2-static.key /etc/openvpn/static.key" >&2
        echo "      pct exec 204 -- chmod 600 /etc/openvpn/static.key" >&2
        echo "      pct exec 204 -- bash /root/setup.sh b     <- then re-run this" >&2
        echo "" >&2
        echo "  Everything else on this container is configured; only the VPN" >&2
        echo "  is incomplete. Re-run this script once the key is in place." >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        exit 3
    fi
    chmod 600 "$OVPN_KEY" 2>/dev/null || true
    echo "[*] Static key present at ${OVPN_KEY}"
fi

# =============================================================================
# 8. OpenVPN configuration - the WORKING state
#
#    Written wholesale every run, which is what makes setup.sh a reliable reset
#    tool: any config edit break.sh made is simply overwritten.
#
#    SAFETY NOTES on the directives below:
#      * NO `redirect-gateway` anywhere. Ever. It would install a default route
#        through the tunnel and cut the learner's SSH lifeline.
#      * `route-nopull` on the client. In static-key point-to-point mode there
#        is no option pull to begin with, so this is belt-and-braces - but it is
#        the directive that guarantees a future server-side `push "redirect-
#        gateway"` could never reach the client. Keep it.
#      * Only scoped `route` statements for the far site LAN. Never 0.0.0.0/0.
#      * tun-mtu ${GOOD_TUN_MTU} sits well under the ${GOOD_UNDERLAY_MTU}-byte
#        underlay, so an encapsulated full-size tunnel packet still fits on the
#        wire. mssfix additionally clamps TCP. This is the pairing break.sh
#        deliberately destroys.
#      * No `local` bind address: binding to 0.0.0.0 means the service starts
#        even if eth1 comes up late, which keeps the "service is green" red
#        herring dependable.
# =============================================================================
echo "[*] Writing ${OVPN_CONF} ..."

if [ "$ROLE" = "a" ]; then
cat > "$OVPN_CONF" << EOF
# lab2-tunnel-failure :: Site-A gateway - OpenVPN SERVER (static key, p2p)
# Managed by setup.sh. Re-running setup.sh overwrites this file.
dev tun
proto udp
port 1194
# Bind to the lab carrier segment only. Without this the daemon also listened on
# the management IP (192.168.10.203), reachable across the whole tailnet, for no
# benefit to the exercise. lab-netprep.service is ordered Before= this unit, so
# eth1 is guaranteed to exist by the time OpenVPN starts. (D16)
local ${LAB_IP}

# Point-to-point tunnel addressing: local endpoint, then remote endpoint.
ifconfig ${TUN_LOCAL} ${TUN_REMOTE}

# Pre-shared static key. Both peers use the identical file.
secret ${OVPN_KEY}
cipher AES-256-CBC
auth SHA256

# MTU pairing: tunnel payload stays comfortably under the underlay MTU.
tun-mtu ${GOOD_TUN_MTU}
mssfix ${GOOD_MSSFIX}

# Reach the far site's office LAN across the tunnel. SCOPED route only.
# There is no redirect-gateway here and there must never be one.
route ${FAR_LAN} ${FAR_LAN_MASK}

# The client may re-appear from a different source port after a NAT/link blip.
float

keepalive 10 60
persist-key
persist-tun
verb 3
EOF
else
cat > "$OVPN_CONF" << EOF
# lab2-tunnel-failure :: Site-B gateway - OpenVPN CLIENT (static key, p2p)
# Managed by setup.sh. Re-running setup.sh overwrites this file.
dev tun
proto udp
remote ${PEER_LAB_IP} 1194
nobind

# Point-to-point tunnel addressing: local endpoint, then remote endpoint.
ifconfig ${TUN_LOCAL} ${TUN_REMOTE}

# Pre-shared static key. Both peers use the identical file.
secret ${OVPN_KEY}
cipher AES-256-CBC
auth SHA256

# MTU pairing: tunnel payload stays comfortably under the underlay MTU.
tun-mtu ${GOOD_TUN_MTU}
mssfix ${GOOD_MSSFIX}

# *** LIFELINE GUARD ***
# Refuse any routing option the peer might ever try to push. Combined with the
# absence of redirect-gateway, this makes it impossible for the tunnel to
# replace the default route via ${MGMT_GW} and strand the learner.
route-nopull

# Reach the far site's office LAN across the tunnel. SCOPED route only.
route ${FAR_LAN} ${FAR_LAN_MASK}

keepalive 10 60
persist-key
persist-tun
verb 3
EOF
fi
chmod 600 "$OVPN_CONF"

# =============================================================================
# 9. Enable + start the tunnel
# =============================================================================
echo "[*] Enabling ${OVPN_UNIT} ..."
systemctl enable "$OVPN_UNIT" >/dev/null 2>&1 || echo "    WARNING: could not enable ${OVPN_UNIT}"
systemctl restart "$OVPN_UNIT" >/dev/null 2>&1 || echo "    WARNING: could not start ${OVPN_UNIT}"

# Give the daemon a moment to create tun0 and settle.
for i in $(seq 1 10); do
    ip link show tun0 >/dev/null 2>&1 && break
    sleep 1
done

# =============================================================================
# 10. Verify the WORKING state
#
#     NOTE on role a: the server has no `remote`, so it only learns the peer's
#     address once the client sends its first packet. Running setup.sh on a
#     BEFORE b exists therefore cannot ping the tunnel yet - that is reported as
#     a WARN, not a FAIL. Re-run setup.sh a afterwards for a clean bill.
# =============================================================================
echo "[*] Testing the tunnel ..."
TUN_PING_OK=0
for i in $(seq 1 20); do
    if ping -c1 -W1 "$TUN_REMOTE" >/dev/null 2>&1; then
        TUN_PING_OK=1
        break
    fi
    sleep 1
done
[ "$TUN_PING_OK" -eq 1 ] \
    && echo "    tunnel peer ${TUN_REMOTE} reachable" \
    || echo "    tunnel peer ${TUN_REMOTE} not answering yet"

# End-to-end site LAN test from the simulated host behind this gateway. This is
# the check that actually exercises forwarding, routing AND MTU.
SITE_PING_OK=0
if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$SITE_NS"; then
    ip netns exec "$SITE_NS" ping -c1 -W2 "$FAR_HOST_IP" >/dev/null 2>&1 && SITE_PING_OK=1
    # Large-payload probe: proves the MTU pairing is sane, not just that ICMP works.
    SITE_BIG_OK=0
    ip netns exec "$SITE_NS" ping -c1 -W2 -M do -s 1200 "$FAR_HOST_IP" >/dev/null 2>&1 && SITE_BIG_OK=1
else
    SITE_BIG_OK=0
fi

# =============================================================================
# 11. Field ticket -> /root/FIELD_TICKET.txt and /etc/motd
#     Kept byte-identical to labs/lab2-tunnel-failure/FIELD_TICKET.txt.
# =============================================================================
echo "[*] Installing field ticket ..."
cat > "$TICKET_FILE" << 'LAB_TICKET_EOF'
================================================================================
                 NORTHSTAR LOGISTICS - IT SERVICE DESK
                        FIELD DISPATCH TICKET
================================================================================

TICKET ID      : NSL-49037
OPENED         : 06:52 local
PRIORITY       : P2 - HIGH (inter-site transfers failing, no data loss reported)
STATUS         : DISPATCHED - awaiting Field Application Engineer
QUEUE          : Network Operations -> Field Services
REPORTER       : Marcus Feld, Site Operations Lead - Site B (Distribution)
CONTACT        : ext. 5108 / mfeld@northstar-logistics.example
ASSIGNED TO    : (you)

--------------------------------------------------------------------------------
AFFECTED SYSTEMS
--------------------------------------------------------------------------------
  Site-A gateway   lab-vpn-a    LAB interface address 10.20.20.10
  Site-B gateway   lab-vpn-b    LAB interface address 10.20.20.20

  The two gateways carry a site-to-site VPN tunnel between the Site-A and
  Site-B office networks. Tunnel transport rides the 10.20.20.0/24 carrier
  segment; the tunnel itself is addressed out of 10.99.99.0/24.

  Site-A is the tunnel server. Site-B is the tunnel client.

--------------------------------------------------------------------------------
HOW TO CONNECT
--------------------------------------------------------------------------------
  Management access is UNAFFECTED and has been confirmed working from the
  office network the entire time. Connect over the management addresses:

      ssh fae@192.168.10.203        (Site-A gateway, lab-vpn-a)
      ssh fae@192.168.10.204        (Site-B gateway, lab-vpn-b)

  Fallback console password is on file with the desk if key auth is not set up
  for your workstation. Do NOT reconfigure the management interface, its
  address, or the default route for any reason - it is the only remote path to
  these boxes and there is nobody on site to recover them from console.

--------------------------------------------------------------------------------
USER COMPLAINT (verbatim from reporter)
--------------------------------------------------------------------------------
  "The VPN says it is connected but nobody at Site B can actually get to
  anything at Site A.

  Here is what is strange. If I ping a machine on the other side, sometimes it
  answers just fine. Small stuff seems OK. But the second anyone tries to
  actually USE it, it dies. Pulling up the shared drive listing works, opening
  a file off it hangs forever. Copying a file over is the worst - it starts,
  it looks like it is going, and then it just stops dead and eventually times
  out. Same thing when the warehouse app tries to sync its nightly batch, it
  hangs partway and never finishes.

  It is not a total outage, which is what is driving everybody crazy. If it
  were just down I would understand it. It looks up. It says it is up. It is
  not up in any way that helps anyone do their job.

  I have had four people ask me this morning if the VPN is down. I do not have
  a good answer for them."

--------------------------------------------------------------------------------
SYMPTOMS OBSERVED / TRIAGE ALREADY PERFORMED BY REPORTER
--------------------------------------------------------------------------------
  * Reporter restarted the VPN service on BOTH gateways. It comes back and
    reports active (running) on both. No change to the symptoms.
  * Reporter rebooted the Site-B gateway. VPN came back up on its own and
    still reports active (running). No change to the symptoms.
  * Small test traffic between the sites sometimes succeeds. Large transfers
    consistently stall partway and then time out.
  * No error is ever shown to the user - transfers hang rather than fail fast.
  * Both gateways remain fully reachable over management the entire time.
  * Reporter states nothing was changed. There was, however, an unscheduled
    carrier maintenance window on the inter-site link two nights ago.
    (Treat that timing as a lead, not as a conclusion.)

--------------------------------------------------------------------------------
SCOPE OF WORK
--------------------------------------------------------------------------------
  1. Restore full end-to-end usability between the Site-A and Site-B office
     networks across the tunnel - not just reachability, but sustained
     transfer of real payloads.
  2. Verify the fix survives a reboot of both gateways.
  3. Document root cause and the exact commands used, for the change record.

  OUT OF SCOPE / HARD CONSTRAINT: the management interface, its address, and
  the default route must not be modified on either gateway. If you lose
  management connectivity this ticket becomes a truck roll and both sites stay
  degraded until tomorrow.

--------------------------------------------------------------------------------
NOTES
--------------------------------------------------------------------------------
  "The service is running" is a statement about the service, not about the
  path. Confirm the data plane independently of the control plane.

  Assume the problem may be more than one thing, and that the pieces may be
  split across the two gateways. The reporter is not a network person and
  their description reflects what they could see from the surface. Work the
  layers in order, re-test after every single change, and do not assume the
  first thing you find is the only thing you will find.

================================================================================
                        END OF TICKET  -  NSL-49037
================================================================================
LAB_TICKET_EOF

chmod 644 "$TICKET_FILE"
cp "$TICKET_FILE" /etc/motd
chmod 644 /etc/motd

# =============================================================================
# 12. Verification
# =============================================================================
echo ""
echo "=== Verification ==="
# Track verification failures so this script exits non-zero. Previously it ended
# with an unconditional `exit 0`, so deploy.sh reported "setup complete" even
# when tun0 was missing, the static key never generated, or openvpn was dead.
# NOTE: the [WARN] cases below stay plain echoes on purpose - they are legitimately
# expected mid-deploy (role a runs before role b exists). (C9)
VERIFY_FAILED=0
bad() { echo "[FAIL] $*"; VERIFY_FAILED=$((VERIFY_FAILED+1)); }

MISSING=""
# tracepath is listed deliberately: it is the intended discovery tool for the
# hardest fault layer. If it is silently missing, the candidate loses the path
# to that layer and setup.sh would otherwise report all-green.
for p in openvpn openssl curl tcpdump ping tracepath traceroute mtr netstat sudo sysctl; do
    command -v "$p" >/dev/null 2>&1 || MISSING="${MISSING} ${p}"
done
if [ -z "$MISSING" ]; then
    echo "[OK]   packages installed"
else
    bad "packages missing:${MISSING}"
fi

if systemctl is-active --quiet ssh; then
    echo "[OK]   ssh active"
else
    bad "ssh not active"
fi

if id "$FAE_USER" >/dev/null 2>&1; then
    echo "[OK]   user ${FAE_USER} exists"
else
    bad "user ${FAE_USER} missing"
fi

if ip -4 addr show dev "$LAB_IF" 2>/dev/null | grep -q "inet ${LAB_IP}/${LAB_CIDR}\b"; then
    echo "[OK]   ${LAB_IF} address is ${LAB_IP}/${LAB_CIDR}"
else
    bad "${LAB_IF} address is not ${LAB_IP}/${LAB_CIDR}"
fi

CUR_MTU="$(cat /sys/class/net/${LAB_IF}/mtu 2>/dev/null)"
if [ "${CUR_MTU:-0}" = "$GOOD_UNDERLAY_MTU" ]; then
    echo "[OK]   ${LAB_IF} mtu is ${GOOD_UNDERLAY_MTU}"
else
    bad "${LAB_IF} mtu is ${CUR_MTU:-unknown}, expected ${GOOD_UNDERLAY_MTU}"
fi

if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
    echo "[OK]   ip_forward enabled"
else
    bad "ip_forward disabled - a site gateway cannot route without it"
fi

if [ -s "$OVPN_KEY" ]; then
    echo "[OK]   static key present at ${OVPN_KEY}"
else
    bad "static key missing at ${OVPN_KEY}"
fi

if systemctl is-active --quiet "$OVPN_UNIT"; then
    echo "[OK]   ${OVPN_UNIT} active"
else
    bad "${OVPN_UNIT} not active"
fi

if ip link show tun0 >/dev/null 2>&1; then
    echo "[OK]   tun0 present"
else
    bad "tun0 missing - check /dev/net/tun passthrough in the CT config"
fi

if ip -4 route show "$FAR_LAN_CIDR" 2>/dev/null | grep -q .; then
    echo "[OK]   route to far site LAN ${FAR_LAN_CIDR} installed"
else
    bad "no route to far site LAN ${FAR_LAN_CIDR}"
fi

if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$SITE_NS"; then
    echo "[OK]   simulated site LAN host ${SITE_HOST_IP} up in netns ${SITE_NS}"
else
    bad "netns ${SITE_NS} missing (fell back to dummy site0 - forwarding fault will not be observable end-to-end)"
fi

if [ "$TUN_PING_OK" -eq 1 ]; then
    echo "[OK]   tunnel ping ${TUN_LOCAL} -> ${TUN_REMOTE} works"
elif [ "$ROLE" = "a" ]; then
    echo "[WARN] tunnel ping to ${TUN_REMOTE} failed - EXPECTED if role b is not"
    echo "       set up yet. The server has no 'remote' and only learns the peer"
    echo "       when the client dials in. Re-run 'setup.sh a' after b is done."
else
    bad "tunnel ping ${TUN_LOCAL} -> ${TUN_REMOTE} failed"
fi

if [ "$SITE_PING_OK" -eq 1 ]; then
    echo "[OK]   site-to-site ${SITE_HOST_IP} -> ${FAR_HOST_IP} works"
else
    echo "[WARN] site-to-site ${SITE_HOST_IP} -> ${FAR_HOST_IP} failed (expected until BOTH roles are set up)"
fi

if [ "$SITE_BIG_OK" -eq 1 ]; then
    echo "[OK]   large-payload probe (1200B, DF) crosses the tunnel"
else
    echo "[WARN] large-payload probe failed (expected until BOTH roles are set up)"
fi

if [ -s "$TICKET_FILE" ] && [ -s /etc/motd ]; then
    echo "[OK]   ticket present at ${TICKET_FILE} and /etc/motd"
else
    bad "ticket missing"
fi

# Sanity: confirm we did not disturb the lifeline. setup.sh never writes to eth0
# or the default route, so this is a canary, not a fix-up.
if ip -4 addr show dev "$MGMT_IF" 2>/dev/null | grep -q "inet ${MGMT_IP}/" \
   && ip -4 route show default 2>/dev/null | grep -q "via ${MGMT_GW}"; then
    echo "[OK]   mgmt lifeline intact (${MGMT_IF} ${MGMT_IP}, default via ${MGMT_GW})"
else
    bad "mgmt lifeline NOT as expected - investigate before proceeding"
fi

echo ""
if [ "$VERIFY_FAILED" -eq 0 ]; then
    echo "Setup complete for role '${ROLE}'. Baseline is the WORKING state."
    echo "Run break.sh <role> on BOTH containers to inject the lab faults."
    exit 0
else
    echo "Setup for role '${ROLE}' completed with ${VERIFY_FAILED} failure(s) - see [FAIL] lines above."
    exit 1
fi
