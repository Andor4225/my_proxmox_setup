#!/bin/bash
# =============================================================================
# lab4-name-resolution :: setup.sh
# -----------------------------------------------------------------------------
# Builds the WORKING baseline state for the "Name Resolution Failure" lab, and
# doubles as the RESET tool: re-running it after break.sh strips every injected
# fault and returns the container to the known-good state.
#
# Runs INSIDE a Debian 12 privileged LXC container as root, e.g.:
#     pct push 206 setup.sh /root/setup.sh && pct exec 206 -- bash /root/setup.sh a
#     pct push 207 setup.sh /root/setup.sh && pct exec 207 -- bash /root/setup.sh b
#
# Usage: setup.sh <role>       role = a (server) | b (client)
#
# TOPOLOGY (fixed, do not change):
#   CT 206 lab-dns-a : eth0 192.168.10.206/24 gw 192.168.10.1 (vmbr0, MGMT)
#                      eth1 10.40.40.10/24    NO gateway      (vmbr3, LAB)
#                      runs dnsmasq -> DNS + DHCP for the lab segment
#   CT 207 lab-dns-b : eth0 192.168.10.207/24 gw 192.168.10.1 (vmbr0, MGMT)
#                      eth1 10.40.40.x/24 via DHCP, NO gateway (vmbr3, LAB)
#
#   vmbr3 is ISOLATED (bridge-ports none, no uplink). Nothing on it can leak.
#
# WHAT THIS LAB TEACHES
#   The single most misdiagnosed class of field problem: things that look like
#   network outages but are name resolution. The skills being drilled are
#     - timeout   vs REFUSED vs SERVFAIL vs NXDOMAIN  (four different causes)
#     - `ping <name>` failing while `ping <ip>` works is a RESOLUTION problem
#     - `dig` talks to a server directly and IGNORES /etc/hosts and nsswitch,
#       while `getent`/`ping`/the application do NOT. When they disagree, the
#       disagreement is the evidence.
#
# *** SACRED INVARIANT ***
#   eth0, its address, and the default route via 192.168.10.1 are the learner's
#   SSH lifeline over Tailscale from a travel laptop. NOTHING here may touch
#   them. There is no bare `ip route add default` / `ip route del default` in
#   this file, and there must never be one. Every write is scoped to eth1 or the
#   10.40.40.0/24 prefix. The script ends with a MGMT GUARD.
#
# *** DHCP SAFETY - READ TWICE ***
#   This lab runs a DHCP SERVER. A DHCP server that answered on eth0 would start
#   handing out 10.40.40.x leases to the real house LAN. Every one of the
#   following is set, deliberately redundantly:
#       interface=eth1
#       except-interface=eth0
#       except-interface=lo
#       bind-interfaces
#       no-dhcp-interface=eth0
#       no-dhcp-interface=lo
#       dhcp-range strictly inside 10.40.40.0/24
#   Plus: we ABORT before starting dnsmasq if eth1 is missing or is not on
#   10.40.40.0/24, and we ABORT AFTER starting it if the listening-socket table
#   shows dnsmasq on the mgmt address or on a wildcard address.
#
# *** DHCP CLIENT SAFETY ***
#   A DHCP client is just as dangerous as a DHCP server here: by default dhclient
#   installs the offered default route and rewrites /etc/resolv.conf. Either one
#   would hijack the management path. Three independent brakes are installed:
#       1. server side  - `dhcp-option=3` with no value = send NO router option
#       2. client conf  - a scoped `request` list that never asks for `routers`
#                         or `domain-name-servers` (both in a dedicated -cf file
#                         and as an `interface "eth1"` block in dhclient.conf,
#                         so an ifupdown-launched dhclient is covered too)
#       3. enter hook   - for eth1 only: neuters make_resolv_conf and blanks
#                         new_routers / classless-static-route variables
#   and afterwards we assert the default route is still exactly one entry via
#   192.168.10.1 dev eth0.
#
# set -e is deliberately NOT used: one non-fatal failure (a package already at
# latest, a peer not yet built) must not abort the rest of the configuration and
# skip the guard. Failures are handled explicitly and tracked in VERIFY_FAILED.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        MGMT_IP="192.168.10.206"
        HOSTNAME_EXPECTED="lab-dns-a"
        LAB_IP="10.40.40.10"          # static, this box IS the services box
        LAB_ADDR_MODE="static"
        ;;
    b)
        MGMT_IP="192.168.10.207"
        HOSTNAME_EXPECTED="lab-dns-b"
        LAB_IP=""                      # learned from DHCP
        LAB_ADDR_MODE="dhcp"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>   (a = server/CT206, b = client/CT207)" >&2
        exit 2
        ;;
esac

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
LAB_CIDR=24
LAB_NET="10.40.40.0/24"
LAB_PREFIX="10.40.40."
DNS_SERVER="10.40.40.10"           # the lab's resolver = CT 206's eth1
FALLBACK_DNS="8.8.8.8"             # site/mgmt resolver, keeps apt alive
ZONE="plant.northstar.example"
POOL_START="10.40.40.100"
POOL_END="10.40.40.150"
# Documented static fallback for the client if DHCP cannot be reached at boot
# (e.g. while the lab is armed and the server's DNS/DHCP service is crippled).
# Deliberately OUTSIDE the DHCP pool so it can never collide with a lease.
B_FALLBACK_IP="10.40.40.200"

FAE_USER="fae"
FAE_PASS="faelab123"               # documented lab fallback password (throwaway lab)

DNSMASQ_MAIN="/etc/dnsmasq.conf"
DNSMASQ_DIR="/etc/dnsmasq.d"
CONF_SERVICE="${DNSMASQ_DIR}/10-lab-plant.conf"     # interface/DHCP config (fault 1 target)
CONF_RECORDS="${DNSMASQ_DIR}/20-plant-records.conf" # zone records        (fault 3 target)
CONF_CACHE="${DNSMASQ_DIR}/90-plant-cache.conf"     # TTL knobs - ONLY exists when armed

BASE_SCRIPT="/usr/local/sbin/lab4-net.sh"
BASE_UNIT="lab4-net.service"
BASE_UNIT_PATH="/etc/systemd/system/${BASE_UNIT}"
FAULT_SCRIPT="/usr/local/sbin/lab4-faults.sh"
FAULT_UNIT="lab4-faults.service"
FAULT_UNIT_PATH="/etc/systemd/system/${FAULT_UNIT}"

DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
DHCLIENT_LAB_CONF="/etc/dhcp/dhclient-eth1.conf"
DHCLIENT_HOOK="/etc/dhcp/dhclient-enter-hooks.d/lab4-eth1-safety"
DHCLIENT_LEASES="/var/lib/dhcp/dhclient.eth1.leases"

TICKET_FILE="/root/FIELD_TICKET.txt"
HOSTS_FAULT_TAG="LAB4-FAULT"

VERIFY_FAILED=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; VERIFY_FAILED=1; }
warn() { echo "[WARN] $*"; }

echo "=============================================================="
echo " lab4-name-resolution setup :: role=${ROLE} (${HOSTNAME_EXPECTED})"
echo " mgmt=${MGMT_IP} (untouchable)   lab=${LAB_IF} on ${LAB_NET} (${LAB_ADDR_MODE})"
echo "=============================================================="

# =============================================================================
# MGMT GUARD
#
# Asserts (a) eth0 still holds the expected 192.168.10.20X address and (b) there
# is EXACTLY ONE default route and it is via 192.168.10.1 dev eth0.
#
# Implementation note that matters: this deliberately does NOT do
#   `ip ... | grep -q ...`
# Under `set -o pipefail` the exit status of such a pipeline is non-zero if
# EITHER command fails, which can invert the meaning of the test in ways that
# are invisible on inspection. We capture command output into a variable first,
# then test the string. Same reason we count default routes by looping over the
# captured text instead of piping into `grep -c`.
#
# The guard is READ-ONLY. A guard that repairs state can mask the very bug it
# exists to catch.
# =============================================================================
mgmt_guard() {
    local ctx="${1:-final check}"
    local addr_out route_out line
    local addr_ok=0 route_ok=0 def_count=0

    addr_out="$(ip -4 addr show dev "$MGMT_IF" 2>/dev/null)"
    case "$addr_out" in
        *"inet ${MGMT_IP}/"*) addr_ok=1 ;;
        *)                    addr_ok=0 ;;
    esac

    route_out="$(ip -4 route show default 2>/dev/null)"
    while IFS= read -r line; do
        case "$line" in
            default*)
                def_count=$((def_count + 1))
                case "$line" in
                    *"via ${MGMT_GW} dev ${MGMT_IF}"*) route_ok=1 ;;
                esac
                ;;
        esac
    done <<EOF
${route_out}
EOF

    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ] && [ "$def_count" -eq 1 ]; then
        echo "[OK]   MGMT GUARD (${ctx}): ${MGMT_IF}=${MGMT_IP}, exactly 1 default via ${MGMT_GW}"
        return 0
    fi

    echo ""
    echo "################################################################"
    echo "#                                                              #"
    echo "#   FAIL - MANAGEMENT LIFELINE COMPROMISED                     #"
    echo "#                                                              #"
    echo "################################################################"
    echo "#  Context        : ${ctx}"
    echo "#  ${MGMT_IF} = ${MGMT_IP}/24        -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    echo "#  default via ${MGMT_GW} dev ${MGMT_IF} -> $([ "$route_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    echo "#  default route count      -> ${def_count} (expected exactly 1)"
    echo "################################################################"
    echo ""
    echo "--- ${MGMT_IF} addresses ---"
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null || echo "(none)"
    echo "--- default routes ---"
    printf '%s\n' "${route_out:-(none)}"
    echo ""
    echo "Recover from the Proxmox host console:"
    echo "    pct exec <CTID> -- ip addr add ${MGMT_IP}/24 dev ${MGMT_IF}"
    echo "    pct exec <CTID> -- ip route add default via ${MGMT_GW} dev ${MGMT_IF}"
    echo ""
    exit 1
}

# =============================================================================
# 1. IDENTITY ASSERTION - fail fast, BEFORE anything is written.
#
#    lab1 only warns here. This lab hard-fails, because role a starts a DHCP
#    SERVER. Running `setup.sh a` against the wrong container would stand up a
#    DHCP server on a box whose eth1 may be on a different segment. The cost of
#    a false positive (a hostname that was never set) is a re-run; the cost of a
#    false negative is a rogue DHCP server. Fail closed.
# =============================================================================
echo "[*] Identity assertion ..."
CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_EXPECTED" ]; then
    echo "ERROR: hostname is '${CURRENT_HOSTNAME}' but role '${ROLE}' expects '${HOSTNAME_EXPECTED}'." >&2
    echo "       role a = CT 206 = lab-dns-a (DNS/DHCP SERVER)" >&2
    echo "       role b = CT 207 = lab-dns-b (client)" >&2
    echo "       Refusing to write anything. Fix the hostname or the target CTID." >&2
    exit 2
fi
ok "hostname ${CURRENT_HOSTNAME} matches role ${ROLE}"

# Pre-flight lifeline check: if the lifeline is already wrong we do not know what
# state this container is in and must not start reconfiguring it.
mgmt_guard "pre-flight"

# Refuse to proceed if eth1 is actually carrying the management address (NIC
# ordering mistake in the CT config). Everything below writes to eth1.
LAB_IF_ADDRS="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null || true)"
case "$LAB_IF_ADDRS" in
    *"inet 192.168.10."*)
        echo "ERROR: ${LAB_IF} carries a 192.168.10.x address - that is the MANAGEMENT" >&2
        echo "       subnet. The CT's NICs look mis-mapped. Refusing to touch ${LAB_IF}." >&2
        exit 2
        ;;
esac

# =============================================================================
# 2. Wait for the management network before apt.
#    Fresh LXC containers need a moment to settle; an immediate apt-get update
#    otherwise fails. Probe the MGMT gateway (never modify anything about it).
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
[ "$NET_UP" -eq 1 ] || warn "${MGMT_GW} not answering; continuing anyway"

# =============================================================================
# 3. Locale - suppress the Debian LXC 'Setting locale failed' spam.
#    Only export LC_ALL/LANG if locale-gen actually succeeded; exporting a locale
#    that does not exist makes the spam worse, not better.
# =============================================================================
echo "[*] Configuring locale ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq locales >/dev/null 2>&1
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
if locale-gen >/dev/null 2>&1; then
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    echo "    en_US.UTF-8 generated and exported"
else
    warn "locale-gen failed; leaving LC_ALL/LANG unset (cosmetic only)"
fi

# =============================================================================
# 4. Packages - the diagnostic toolkit. Each maps to a discovery path.
#
#    dnsutils is the star of this lab: `dig` is the only common tool that talks
#    to a nameserver DIRECTLY, bypassing /etc/hosts and /etc/nsswitch.conf. That
#    property is exactly what makes it disagree with `getent`/`ping` when the
#    hosts file is lying, which is the whole point of fault 2.
#
#    iptables is added to role a beyond the base list because the lab's reset
#    path must be able to REMOVE a scoped INPUT rule that break.sh installs. A
#    reset tool that cannot undo a fault is not a reset tool.
# =============================================================================
echo "[*] Installing packages ..."
if [ "$ROLE" = "a" ]; then
    PKGS="dnsmasq dnsutils curl iproute2 iputils-ping tcpdump net-tools openssh-server sudo iptables"
else
    PKGS="dnsutils isc-dhcp-client curl iproute2 iputils-ping tcpdump net-tools openssh-server sudo netcat-openbsd"
fi
if ! apt-get install -y -qq $PKGS >/dev/null 2>&1; then
    echo "    first attempt failed, retrying after apt-get update ..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq $PKGS >/dev/null 2>&1 || warn "some packages may be missing (verified below)"
fi

# =============================================================================
# 5. FAE user - the account the learner logs in as.
#    DELIBERATELY NO ROOT PASSWORD: sshd runs PermitRootLogin prohibit-password
#    and these CTs sit in a range reachable across the whole tailnet. Root
#    console access stays available from the host via `pct enter <CTID>`.
# =============================================================================
echo "[*] Ensuring user '${FAE_USER}' ..."
if id "$FAE_USER" >/dev/null 2>&1; then
    echo "    user already exists"
else
    useradd -m -s /bin/bash "$FAE_USER" && echo "    user created"
fi
usermod -aG sudo "$FAE_USER" 2>/dev/null || warn "could not add ${FAE_USER} to sudo"
echo "${FAE_USER}:${FAE_PASS}" | chpasswd 2>/dev/null || warn "could not set ${FAE_USER} password"

# Seed authorized_keys from root's, IF root has any.
#
# NOTE FOR THE DEPLOYER: this reads /root/.ssh/authorized_keys INSIDE the
# container, which on a fresh build is empty. Key seeding is therefore the
# HOST's job (deploy.sh `keys`), and it must be re-run after every snapshot
# rollback, because the clean-baseline snapshot predates key seeding.
if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$FAE_USER" -g "$FAE_USER" "/home/${FAE_USER}/.ssh"
    install -m 600 -o "$FAE_USER" -g "$FAE_USER" \
        /root/.ssh/authorized_keys "/home/${FAE_USER}/.ssh/authorized_keys"
    echo "    authorized_keys seeded from /root/.ssh/authorized_keys"
else
    echo "    no /root/.ssh/authorized_keys to seed (host must run the keys step)"
fi

# =============================================================================
# 6. SSH - port 22 only. Debian 12 uses ssh.socket socket activation, which
#    IGNORES the Port directive in sshd_config. That only bites if you move off
#    22, so we deliberately do not change the port and need no socket override.
# =============================================================================
echo "[*] Enabling ssh ..."
systemctl enable --now ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1
systemctl is-active --quiet ssh || warn "ssh not active (verified below)"

# =============================================================================
# 7. RESET - remove everything break.sh may have left behind.
#
#    This runs BEFORE the baseline is (re)written so the good config lands on a
#    clean slate. Everything here is scoped to the lab: eth1, the lab dnsmasq
#    files, a tagged /etc/hosts line, and INPUT rules that name `-i eth1`.
# =============================================================================
echo "[*] Clearing any previously injected lab faults ..."

# 7a. Fault persistence unit. Unconditional: disable/rm/daemon-reload are all
#     idempotent, and gating on a `list-unit-files` probe risks leaving a stale
#     unit behind if the probe misses while systemd is still coming up.
systemctl disable --now "$FAULT_UNIT" >/dev/null 2>&1 || true
if [ -f "$FAULT_UNIT_PATH" ]; then
    rm -f "$FAULT_UNIT_PATH"
    echo "    removed ${FAULT_UNIT}"
fi
rm -f "$FAULT_SCRIPT"
systemctl daemon-reload >/dev/null 2>&1 || true

# 7b. Fault 2 residue: the tagged /etc/hosts line.
#     Matched on the tag, not on the name, so we can never delete a legitimate
#     entry. Rewritten via a temp file + mv so a crash mid-write cannot leave a
#     truncated /etc/hosts (which would break sudo hostname lookups).
if [ -f /etc/hosts ] && grep -q "$HOSTS_FAULT_TAG" /etc/hosts 2>/dev/null; then
    HOSTS_TMP="$(mktemp /etc/hosts.lab4.XXXXXX)"
    if grep -v "$HOSTS_FAULT_TAG" /etc/hosts > "$HOSTS_TMP" && [ -s "$HOSTS_TMP" ]; then
        chmod 644 "$HOSTS_TMP"
        mv -f "$HOSTS_TMP" /etc/hosts
        echo "    removed tagged fault line(s) from /etc/hosts"
    else
        rm -f "$HOSTS_TMP"
        bad "could not safely rewrite /etc/hosts - left untouched"
    fi
fi

# 7c. Fault 1 residue: the scoped INPUT drop rules.
#     Scoped by `-i eth1`, so this loop is structurally incapable of touching a
#     rule that affects the management interface. Bounded to 20 iterations so a
#     misbehaving iptables can never spin forever.
if [ "$ROLE" = "a" ] && command -v iptables >/dev/null 2>&1; then
    for proto in udp tcp; do
        n=0
        while iptables -C INPUT -i "$LAB_IF" -p "$proto" --dport 53 -j DROP 2>/dev/null; do
            iptables -D INPUT -i "$LAB_IF" -p "$proto" --dport 53 -j DROP 2>/dev/null || break
            echo "    removed INPUT drop rule (${proto}/53 on ${LAB_IF})"
            n=$((n + 1))
            [ "$n" -ge 20 ] && break
        done
    done
fi

# 7d. Fault 3 residue: the TTL/cache override file. Its presence IS the fault,
#     so removing it is the reset. (It sorts AFTER the record file on purpose -
#     see break.sh.)
if [ -f "$CONF_CACHE" ]; then
    rm -f "$CONF_CACHE"
    echo "    removed ${CONF_CACHE}"
fi

# 7e. Role b only: clear the DHCP fallback state.
#
#     WHY THIS EXISTS: while fault 1 is armed the segment's DHCP service is down,
#     so lab4-net.sh legitimately falls back to the documented static address.
#     The boot helper then skips dhclient on every later run because eth1 already
#     HAS a 10.40.40.x address. Without this block, a reset would leave the
#     client permanently on the static fallback and the lab's "confirm the client
#     is still addressed automatically" acceptance criterion could never pass
#     again. A reset that does not actually reset is worse than no reset.
#
#     Scoped: the delete names the exact fallback address and the exact device.
#     It cannot touch a real lease, and it cannot touch eth0.
if [ "$ROLE" = "b" ]; then
    CUR_B="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null || true)"
    case "$CUR_B" in
        *"inet ${B_FALLBACK_IP}/"*)
            if ip addr del "${B_FALLBACK_IP}/${LAB_CIDR}" dev "$LAB_IF" 2>/dev/null; then
                echo "    removed static fallback ${B_FALLBACK_IP} so DHCP is re-attempted"
            else
                warn "could not remove static fallback ${B_FALLBACK_IP} from ${LAB_IF}"
            fi
            ;;
    esac
    # Force a genuinely fresh lease rather than letting dhclient reuse a stored
    # one - "the client still gets an address automatically" must be PROVEN on
    # every reset, not inherited from a previous run.
    rm -f "$DHCLIENT_LEASES"
fi

# =============================================================================
# 8. LAB interface (eth1)
#
#    *** CRITICAL LXC GOTCHA ***
#    Proxmox REWRITES /etc/network/interfaces on EVERY container start, emitting
#    one stanza per configured NIC. A pre-existing `iface eth1` stanza is the
#    NORMAL case, not an error - never abort on it, and never add a second one.
#    A duplicate `iface` stanza is a WHOLE-CONFIG parse failure: `ifup -a` aborts
#    and eth0 never gets its address at boot, which locks the learner out with
#    console-only recovery. The ticket explicitly tells them to reboot, so this
#    path WILL be exercised.
#
#    Resolution: we never write to /etc/network/interfaces.d at all. A systemd
#    oneshot (lab4-net.service) owns eth1's state. It is ordered after
#    networking.service, so whatever PVE/ifupdown does first, we run last.
# =============================================================================
echo "[*] Removing any legacy interfaces.d fragment from older revisions ..."
rm -f "/etc/network/interfaces.d/${LAB_IF}"

if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
    echo "ERROR: ${LAB_IF} does not exist. Check the CT's net1 device is on vmbr3." >&2
    exit 3
fi

# =============================================================================
# 9. nsswitch - make the resolution ORDER explicit.
#
#    Debian's default is `hosts: files dns`, i.e. /etc/hosts wins over DNS. The
#    lab depends on that ordering (fault 2 is a lying /etc/hosts entry that
#    beats a correct DNS answer). We set it explicitly rather than assume it, so
#    the lab behaves identically on every reset and on any template revision.
#    This is baseline-correct configuration, not a fault.
# =============================================================================
echo "[*] Pinning nsswitch hosts order ..."
if [ -f /etc/nsswitch.conf ]; then
    NSS_TMP="$(mktemp /etc/nsswitch.lab4.XXXXXX)"
    if sed 's/^[[:space:]]*hosts:.*/hosts:          files dns/' /etc/nsswitch.conf > "$NSS_TMP" \
       && [ -s "$NSS_TMP" ]; then
        chmod 644 "$NSS_TMP"
        mv -f "$NSS_TMP" /etc/nsswitch.conf
    else
        rm -f "$NSS_TMP"
        warn "could not rewrite /etc/nsswitch.conf"
    fi
fi
NSS_HOSTS_LINE="$(grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null || true)"
echo "    ${NSS_HOSTS_LINE:-<no hosts line>}"

# =============================================================================
# 10. Role A only :: dnsmasq configuration
#
#     Split across THREE files on purpose, so the injected faults stay isolated
#     from one another and the lab layers deterministically:
#       10-lab-plant.conf   service binding + DHCP   (fault 1 rewrites this)
#       20-plant-records.conf  the zone records      (fault 3 rewrites this)
#       90-plant-cache.conf    TTL knobs             (fault 3 CREATES this)
#     No directive appears in more than one file, so there is never a
#     "which one wins" ambiguity - dnsmasq's merge order can never make the lab
#     behave differently from one run to the next.
# =============================================================================
if [ "$ROLE" = "a" ]; then
    echo "[*] Configuring dnsmasq (server role) ..."

    # ---- 10.1 SAFETY ABORT: eth1 must be on the lab subnet BEFORE we ever
    #      start a DHCP server. If eth1 is missing, down, or on some other
    #      subnet, starting dnsmasq risks serving the wrong network. Bail loudly.
    #      We bring eth1 up and give it its address here first, then re-check.
    ip link set "$LAB_IF" up 2>/dev/null || true
    CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null || true)"
    case "$CUR" in
        *"inet ${LAB_IP}/${LAB_CIDR}"*)
            echo "    ${LAB_IF} already ${LAB_IP}/${LAB_CIDR}"
            ;;
        *)
            # Scoped to eth1. `flush` names the device explicitly; eth0 and the
            # default route are never named anywhere in this script.
            ip addr flush dev "$LAB_IF" 2>/dev/null || true
            ip addr add "${LAB_IP}/${LAB_CIDR}" dev "$LAB_IF" 2>/dev/null \
                || bad "could not add ${LAB_IP}/${LAB_CIDR} to ${LAB_IF}"
            echo "    ${LAB_IF} set to ${LAB_IP}/${LAB_CIDR}"
            ;;
    esac

    LAB_ADDR_NOW="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null || true)"
    case "$LAB_ADDR_NOW" in
        *"inet ${LAB_IP}/${LAB_CIDR}"*) : ;;
        *)
            echo "" >&2
            echo "################################################################" >&2
            echo "#  ABORT - REFUSING TO START A DHCP SERVER                      #" >&2
            echo "################################################################" >&2
            echo "  ${LAB_IF} is not ${LAB_IP}/${LAB_CIDR}. A DHCP server started in" >&2
            echo "  this state could answer on the wrong segment. Nothing was" >&2
            echo "  started. Current ${LAB_IF} state:" >&2
            printf '%s\n' "${LAB_ADDR_NOW:-<none>}" | sed 's/^/    /' >&2
            exit 4
            ;;
    esac
    ok "${LAB_IF} verified on ${LAB_NET} - safe to configure dnsmasq"

    # ---- 10.2 Make sure /etc/dnsmasq.conf actually pulls in /etc/dnsmasq.d.
    #      If it does not, everything below is silently ignored and the lab
    #      quietly fails in a way that looks like a fault.
    mkdir -p "$DNSMASQ_DIR"
    if ! grep -qE '^[[:space:]]*conf-dir=/etc/dnsmasq\.d' "$DNSMASQ_MAIN" 2>/dev/null; then
        printf '\n# added by lab4-name-resolution setup.sh\nconf-dir=/etc/dnsmasq.d/,.dpkg-dist,.dpkg-old,.dpkg-new\n' \
            >> "$DNSMASQ_MAIN"
        echo "    enabled conf-dir=/etc/dnsmasq.d in ${DNSMASQ_MAIN}"
    fi

    # ---- 10.3 Refuse to run if some OTHER file in /etc/dnsmasq.d declares an
    #      interface or a DHCP range. That would be an unknown-provenance
    #      binding we have not vetted, and this box runs a DHCP server.
    STRAY=""
    for f in "$DNSMASQ_DIR"/*; do
        [ -f "$f" ] || continue
        case "$f" in
            "$CONF_SERVICE"|"$CONF_RECORDS"|"$CONF_CACHE") continue ;;
        esac
        if grep -qE '^[[:space:]]*(interface|listen-address|dhcp-range|bind-)' "$f" 2>/dev/null; then
            STRAY="${STRAY} ${f}"
        fi
    done
    if [ -n "$STRAY" ]; then
        echo "ERROR: unvetted dnsmasq binding/DHCP directives found in:${STRAY}" >&2
        echo "       Refusing to start a DHCP server with unknown bindings." >&2
        exit 4
    fi

    # ---- 10.4 Service/binding config (fault 1 rewrites THIS file).
    cat > "$CONF_SERVICE" << EOF
# =============================================================================
# lab4-name-resolution :: dnsmasq service + DHCP binding
# Managed by setup.sh. This is the WORKING baseline.
#
# *** EVERY LINE IN THE BINDING BLOCK IS A SAFETY CONTROL ***
# This box runs a DHCP server. eth0 is on the real house LAN. If dnsmasq ever
# answered DHCP on eth0 it would hand 10.40.40.x leases to real household
# devices. The controls below are redundant ON PURPOSE - belt AND braces.
# =============================================================================

# Serve ONLY the isolated lab segment.
interface=${LAB_IF}
# Never bind the management interface, and never bind loopback either.
except-interface=${MGMT_IF}
except-interface=lo
# Bind only the interfaces named above, instead of the wildcard address. Without
# this, dnsmasq binds 0.0.0.0 and filters by interface in userspace - which is
# fine for DNS but leaves a socket on the mgmt address in \`ss\` output, and this
# lab asserts that socket does not exist.
bind-interfaces
# Belt-and-braces: even if the above were somehow misread, no DHCP off eth1.
no-dhcp-interface=${MGMT_IF}
no-dhcp-interface=lo

# --- Upstream --------------------------------------------------------------
# no-resolv is MANDATORY here. This container's /etc/resolv.conf lists
# ${DNS_SERVER} (ourselves) first, so if dnsmasq read it as an upstream we would
# build a query loop against ourselves. Point upstream at the site resolver
# explicitly instead.
no-resolv
server=${FALLBACK_DNS}

# --- Authority -------------------------------------------------------------
# We are AUTHORITATIVE for the plant zone: an unknown name inside it must come
# back NXDOMAIN from us, not get forwarded to the internet. That distinction is
# half the lesson of this lab (NXDOMAIN = "this server knows, and the answer is
# no" vs a timeout = "nothing answered at all").
domain=${ZONE}
local=/${ZONE}/
domain-needed
bogus-priv

# --- DHCP for the lab segment ----------------------------------------------
# Range is strictly inside ${LAB_NET}. It cannot address anything else.
dhcp-range=${POOL_START},${POOL_END},255.255.255.0,24h
# Option 3 (routers) with NO value = send no router option at all.
# The lab segment has no gateway, and a client that installed one could hijack
# the management default route. This is brake #1 of three.
dhcp-option=3
# Option 6 (DNS) points at ourselves. Harmless: our client is configured not to
# request it, but a real plant client would use it.
dhcp-option=6,${DNS_SERVER}

# --- Observability ----------------------------------------------------------
# log-queries makes 'journalctl -u dnsmasq -f' a first-class diagnostic tool.
log-queries
log-dhcp

# DELIBERATELY NO local-ttl / neg-ttl HERE.
# dnsmasq's defaults are correct for a plant zone, and more importantly: a fault
# later drops a 90-plant-cache.conf into this directory that DOES set them. If
# the baseline also set them, both files would declare the same scalar directive
# and the outcome would depend on conf-dir merge order. The lab must behave
# identically on every reset, so exactly one file ever owns any given directive.
EOF
    chmod 644 "$CONF_SERVICE"
    echo "    wrote ${CONF_SERVICE}"

    # ---- 10.5 Zone records (fault 3 rewrites THIS file).
    #      host-record gives both the A record and the matching PTR, so reverse
    #      lookups work too and `dig -x` is available to the learner.
    cat > "$CONF_RECORDS" << EOF
# =============================================================================
# lab4-name-resolution :: ${ZONE} zone records
# Managed by setup.sh. These values are the SOURCE OF TRUTH and must match the
# Building 7 as-built binder quoted in the field ticket.
# =============================================================================
host-record=controller-a.${ZONE},10.40.40.10
host-record=hmi.${ZONE},10.40.40.50
host-record=historian.${ZONE},10.40.40.60
host-record=packer-01.${ZONE},10.40.40.70
host-record=gateway.${ZONE},10.40.40.1
EOF
    chmod 644 "$CONF_RECORDS"
    echo "    wrote ${CONF_RECORDS}"

    # ---- 10.6 Validate the whole merged config BEFORE restarting the service.
    #      `dnsmasq --test` parses /etc/dnsmasq.conf plus the conf-dir. A syntax
    #      error here would leave the service dead, which looks like fault 1 and
    #      would waste the learner's time on a lab bug.
    if ! dnsmasq --test >/dev/null 2>&1; then
        echo "ERROR: dnsmasq --test failed on the baseline config:" >&2
        dnsmasq --test 2>&1 | sed 's/^/    /' >&2
        exit 4
    fi
    ok "dnsmasq --test passed"

    systemctl enable dnsmasq >/dev/null 2>&1 || warn "could not enable dnsmasq"
    if ! systemctl restart dnsmasq >/dev/null 2>&1; then
        bad "dnsmasq failed to restart"
        systemctl status dnsmasq --no-pager -l 2>&1 | sed 's/^/       /'
    fi
    sleep 1

    # ---- 10.7 POST-START SAFETY ASSERTION.
    #      Verify from the KERNEL's socket table - not from the config file we
    #      just wrote - that dnsmasq is not reachable on the management address
    #      and is not on a wildcard address. Config review is not evidence;
    #      the listening socket is.
    #
    #      Note on port 67: dnsmasq's DHCP socket legitimately appears as
    #      0.0.0.0:67 even in bind-interfaces mode, because DHCP requests arrive
    #      as broadcasts and dnsmasq filters them by receiving interface in
    #      userspace. So a wildcard :67 is EXPECTED and is not a failure; a :67
    #      or :53 socket bound to the MGMT ADDRESS is a hard failure.
    SOCKETS="$( { ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null; } || true )"
    SAFETY_VIOLATION=""
    case "$SOCKETS" in
        *"${MGMT_IP}:53"*) SAFETY_VIOLATION="${SAFETY_VIOLATION} listening on ${MGMT_IP}:53" ;;
    esac
    case "$SOCKETS" in
        *"${MGMT_IP}:67"*) SAFETY_VIOLATION="${SAFETY_VIOLATION} listening on ${MGMT_IP}:67" ;;
    esac
    case "$SOCKETS" in
        *"0.0.0.0:53"*)    SAFETY_VIOLATION="${SAFETY_VIOLATION} wildcard 0.0.0.0:53" ;;
    esac
    case "$SOCKETS" in
        *"*:53"*)          SAFETY_VIOLATION="${SAFETY_VIOLATION} wildcard *:53" ;;
    esac
    case "$SOCKETS" in
        *"[::]:53"*)       SAFETY_VIOLATION="${SAFETY_VIOLATION} wildcard [::]:53" ;;
    esac

    if [ -n "$SAFETY_VIOLATION" ]; then
        echo "" >&2
        echo "################################################################" >&2
        echo "#  ABORT - dnsmasq IS EXPOSED OUTSIDE THE LAB SEGMENT           #" >&2
        echo "################################################################" >&2
        echo "  Violations:${SAFETY_VIOLATION}" >&2
        echo "  Stopping and disabling dnsmasq NOW." >&2
        systemctl stop dnsmasq >/dev/null 2>&1
        systemctl disable dnsmasq >/dev/null 2>&1
        echo "  Socket table was:" >&2
        printf '%s\n' "$SOCKETS" | sed 's/^/    /' >&2
        exit 5
    fi
    ok "dnsmasq is NOT listening on ${MGMT_IP} and not on a wildcard :53"
fi

# =============================================================================
# 11. Role B only :: scoped DHCP client plumbing
#
#     Three independent brakes so the DHCP client can never hijack the mgmt path.
#     Written here (not in the boot helper) because they are static files; the
#     boot helper only INVOKES dhclient.
# =============================================================================
if [ "$ROLE" = "b" ]; then
    echo "[*] Installing scoped DHCP client configuration ..."
    mkdir -p /etc/dhcp/dhclient-enter-hooks.d /var/lib/dhcp

    # ---- 11.1 Dedicated -cf file for OUR invocations.
    #      The `request` list is the whole point: we never ask for `routers`
    #      (no default route can be installed) and never ask for
    #      `domain-name-servers` (no resolv.conf rewrite is triggered).
    cat > "$DHCLIENT_LAB_CONF" << 'EOF'
# =============================================================================
# lab4-name-resolution :: SCOPED dhclient configuration for eth1 ONLY.
#
# The `request` list below deliberately OMITS:
#     routers               -> so no default route can ever be installed
#     domain-name-servers   -> so /etc/resolv.conf is never rewritten
# Both of those would hijack the management path, which is the learner's only
# way into this box. Do not add them "for completeness".
#
# The lab segment has no gateway by design. There is nothing to route to.
# =============================================================================
timeout 20;
retry 60;
request subnet-mask, broadcast-address, dhcp-lease-time,
        dhcp-renewal-time, dhcp-rebinding-time, dhcp-server-identifier;
EOF
    chmod 644 "$DHCLIENT_LAB_CONF"
    echo "    wrote ${DHCLIENT_LAB_CONF}"

    # ---- 11.2 Same restriction inside the MAIN dhclient.conf, scoped to eth1.
    #      Reason: if PVE's /etc/network/interfaces declares `iface eth1 inet
    #      dhcp`, ifupdown launches dhclient with the DEFAULT config at boot,
    #      completely bypassing our -cf file. An `interface "eth1" { ... }`
    #      block covers that path too. eth0 is untouched by this block.
    #      Rewritten idempotently between markers.
    touch "$DHCLIENT_CONF"
    DHC_TMP="$(mktemp /etc/dhcp/dhclient.lab4.XXXXXX)"
    awk '
        /^# >>> lab4 eth1 scope >>>$/ { skip = 1 }
        skip != 1 { print }
        /^# <<< lab4 eth1 scope <<<$/ { skip = 0 }
    ' "$DHCLIENT_CONF" > "$DHC_TMP" 2>/dev/null
    {
        echo "# >>> lab4 eth1 scope >>>"
        echo "# Managed by lab4 setup.sh. Applies to eth1 ONLY - eth0 is untouched."
        echo "# No 'routers' and no 'domain-name-servers' are requested, so an"
        echo "# ifupdown-launched dhclient cannot install a default route or"
        echo "# overwrite /etc/resolv.conf on the lab interface."
        echo 'interface "eth1" {'
        echo "    timeout 20;"
        echo "    retry 60;"
        echo "    request subnet-mask, broadcast-address, dhcp-lease-time,"
        echo "            dhcp-renewal-time, dhcp-rebinding-time, dhcp-server-identifier;"
        echo "}"
        echo "# <<< lab4 eth1 scope <<<"
    } >> "$DHC_TMP"
    chmod 644 "$DHC_TMP"
    mv -f "$DHC_TMP" "$DHCLIENT_CONF"
    echo "    scoped eth1 block installed in ${DHCLIENT_CONF}"

    # ---- 11.3 Enter hook: the last line of defence, and the only one that also
    #      covers RFC3442 classless static routes (which can smuggle a default
    #      route in as 0.0.0.0/0 inside option 121 - a `request` list that omits
    #      `routers` does NOT stop that).
    #      Scoped by $interface so eth0 can never be affected.
    cat > "$DHCLIENT_HOOK" << 'EOF'
# =============================================================================
# lab4-name-resolution :: dhclient enter hook - eth1 SAFETY ONLY.
#
# Runs before dhclient-script applies a lease. For eth1 and eth1 only:
#   - make_resolv_conf is neutered, so /etc/resolv.conf is never rewritten.
#     (/etc/resolv.conf is managed by lab4-net.sh and must keep the site
#      resolver as a fallback, or apt on this box stops working.)
#   - new_routers is blanked, so no default route is installed.
#   - the classless-static-route variables are blanked, because option 121 can
#     carry a 0.0.0.0/0 entry that bypasses the `routers` restriction entirely.
#
# eth0 is deliberately NOT matched. Nothing here can affect the management path.
# =============================================================================
case "$interface" in
    eth1)
        make_resolv_conf() { : ; }
        new_routers=''
        old_routers=''
        new_classless_static_routes=''
        new_rfc3442_classless_static_routes=''
        new_domain_name_servers=''
        ;;
esac
EOF
    chmod 644 "$DHCLIENT_HOOK"
    echo "    wrote ${DHCLIENT_HOOK}"
fi

# =============================================================================
# 12. Boot-time baseline helper + unit.
#
#     ONE code path applies the baseline now and re-applies it at every boot, so
#     there is exactly one definition of "correct". Ordered
#         After=network-online.target networking.service
#     NOT network-online.target alone: without an enabled *-wait-online unit that
#     target is reached almost immediately, which races ifupdown and would let
#     us configure eth1 before (or during) ifupdown's own pass.
#
#     WHAT THIS HELPER MUST NOT DO: it must not touch /etc/hosts and must not
#     rewrite the dnsmasq config files. Those are where faults 2 and 3 live, and
#     a boot-time helper that "repaired" them would silently un-break the lab on
#     reboot - exactly what the ticket promises will not happen.
# =============================================================================
echo "[*] Writing baseline helper ${BASE_SCRIPT} ..."
mkdir -p "$(dirname "$BASE_SCRIPT")"
{
    echo '#!/bin/bash'
    echo '# GENERATED BY lab4 setup.sh - baseline lab-segment configuration.'
    echo '# Scoped to eth1 / 10.40.40.0/24 and /etc/resolv.conf ONLY.'
    echo '# Never touches eth0, its address, or the default route.'
    echo "ROLE_DEFAULT=\"${ROLE}\""
    echo "MGMT_IP=\"${MGMT_IP}\""
    echo "LAB_STATIC_IP=\"${LAB_IP}\""
    echo "B_FALLBACK_IP=\"${B_FALLBACK_IP}\""
    echo "DNS_SERVER=\"${DNS_SERVER}\""
    echo "FALLBACK_DNS=\"${FALLBACK_DNS}\""
    cat << 'LAB4_NET_BODY'
set -uo pipefail

ROLE="${1:-$ROLE_DEFAULT}"
MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
LAB_CIDR=24
LAB_PREFIX="10.40.40."
DHCLIENT_LAB_CONF="/etc/dhcp/dhclient-eth1.conf"
DHCLIENT_LEASES="/var/lib/dhcp/dhclient.eth1.leases"
DHCLIENT_PID="/run/dhclient.eth1.pid"

RC=0
log()  { echo "lab4-net[$ROLE]: $*"; }
fail() { log "ERROR: $*"; RC=1; }

# --- MGMT GUARD (identical contract to setup.sh's) ---------------------------
# Captured into variables, then string-tested. Never a pipeline into grep -q:
# under pipefail that construct can invert and report a healthy path as broken
# (or worse, the reverse).
mgmt_guard() {
    local ctx="${1:-final}"
    local addr_out route_out line
    local addr_ok=0 route_ok=0 def_count=0
    addr_out="$(ip -4 addr show dev "$MGMT_IF" 2>/dev/null)"
    case "$addr_out" in *"inet ${MGMT_IP}/"*) addr_ok=1 ;; esac
    route_out="$(ip -4 route show default 2>/dev/null)"
    while IFS= read -r line; do
        case "$line" in
            default*)
                def_count=$((def_count + 1))
                case "$line" in *"via ${MGMT_GW} dev ${MGMT_IF}"*) route_ok=1 ;; esac
                ;;
        esac
    done <<EOF
${route_out}
EOF
    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ] && [ "$def_count" -eq 1 ]; then
        log "MGMT GUARD OK ($ctx)"
        return 0
    fi
    log "########################################################"
    log "#  FAIL - MANAGEMENT LIFELINE COMPROMISED ($ctx)"
    log "#  ${MGMT_IF}=${MGMT_IP} -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    log "#  default via ${MGMT_GW} dev ${MGMT_IF} -> $([ "$route_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    log "#  default route count -> ${def_count} (expected 1)"
    log "########################################################"
    exit 1
}

# Remove any default route that a DHCP client managed to install on the LAB
# interface. This is SCOPED: it only ever deletes a default whose device is
# eth1. It can never match the management default, which is `dev eth0`.
# There is no bare `ip route del default` anywhere in this file.
scrub_lab_default_route() {
    local route_out line gw
    route_out="$(ip -4 route show default 2>/dev/null)"
    while IFS= read -r line; do
        case "$line" in
            default*"dev ${LAB_IF}"*)
                gw=""
                set -- $line
                while [ $# -gt 0 ]; do
                    if [ "$1" = "via" ]; then gw="${2:-}"; fi
                    shift
                done
                if [ -n "$gw" ]; then
                    ip route del default via "$gw" dev "$LAB_IF" 2>/dev/null \
                        && log "removed rogue default via ${gw} dev ${LAB_IF}"
                else
                    ip route del default dev "$LAB_IF" 2>/dev/null \
                        && log "removed rogue default dev ${LAB_IF}"
                fi
                fail "a DHCP-installed default route on ${LAB_IF} was found and removed"
                ;;
        esac
    done <<EOF
${route_out}
EOF
}

# /etc/resolv.conf policy.
#
# WHY BOTH NAMESERVERS: the plant resolver goes first, because that is what
# makes the lab realistic - the application resolves plant names through it.
# The site resolver stays as a fallback so `apt` and anything else on the
# management path keeps working even while the lab is fully broken. Dropping the
# fallback would trade one outage for another.
#
# WHY THIS RUNS AT BOOT: PVE regenerates /etc/resolv.conf from the CT's
# nameserver setting on EVERY container start. Without this, the file reverts to
# the deployer's 8.8.8.8 and the lab's resolution behaviour silently changes.
#
# timeout:2 attempts:1 bounds the damage when the plant resolver is dead: every
# management lookup costs at most ~2s before falling back, instead of the 5s x 2
# glibc default.
write_resolv_conf() {
    local tmp
    tmp="$(mktemp /etc/resolv.conf.lab4.XXXXXX)" || { fail "mktemp for resolv.conf"; return 1; }
    {
        echo "# Managed by lab4-net.service (lab4-name-resolution)."
        echo "# Plant resolver first, site resolver as fallback so apt keeps working."
        echo "nameserver ${DNS_SERVER}"
        echo "nameserver ${FALLBACK_DNS}"
        echo "options timeout:2 attempts:1"
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" /etc/resolv.conf || { fail "could not install /etc/resolv.conf"; return 1; }
    log "resolv.conf: ${DNS_SERVER} then ${FALLBACK_DNS}"
}

mgmt_guard "pre-baseline"

ip link set "$LAB_IF" up 2>/dev/null || true

case "$ROLE" in
  a)
    # --- Server: static lab address -----------------------------------------
    CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
    case "$CUR" in
        *"inet ${LAB_STATIC_IP}/${LAB_CIDR}"*)
            log "${LAB_IF} already ${LAB_STATIC_IP}/${LAB_CIDR}"
            ;;
        *)
            ip addr flush dev "$LAB_IF" 2>/dev/null || true
            ip addr add "${LAB_STATIC_IP}/${LAB_CIDR}" dev "$LAB_IF" 2>/dev/null \
                || fail "could not set ${LAB_IF} to ${LAB_STATIC_IP}/${LAB_CIDR}"
            log "${LAB_IF} -> ${LAB_STATIC_IP}/${LAB_CIDR}"
            ;;
    esac

    write_resolv_conf

    # dnsmasq uses bind-interfaces, so it MUST start after eth1 has an address.
    # At boot, dnsmasq.service can easily win the race and die on "unknown
    # interface". Restarting it here - after the address is confirmed - is the
    # fix. This does NOT repair any fault: the faults live in the config files
    # on disk, which a restart re-reads verbatim.
    CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
    case "$CUR" in
        *"inet ${LAB_STATIC_IP}/${LAB_CIDR}"*)
            if systemctl restart dnsmasq >/dev/null 2>&1; then
                log "dnsmasq restarted after ${LAB_IF} came up"
            else
                fail "dnsmasq failed to restart"
            fi
            ;;
        *)
            fail "refusing to (re)start dnsmasq: ${LAB_IF} is not ${LAB_STATIC_IP}/${LAB_CIDR}"
            ;;
    esac
    ;;

  b)
    # --- Client: address via DHCP, scoped so it cannot hijack anything -------
    HAVE_LAB_ADDR=0
    CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
    case "$CUR" in *"inet ${LAB_PREFIX}"*) HAVE_LAB_ADDR=1 ;; esac

    if [ "$HAVE_LAB_ADDR" -eq 0 ]; then
        # Clear any stale client for this interface only.
        if [ -s "$DHCLIENT_PID" ]; then
            kill "$(cat "$DHCLIENT_PID" 2>/dev/null)" 2>/dev/null || true
            rm -f "$DHCLIENT_PID"
        fi
        mkdir -p /var/lib/dhcp
        # -1 = try once then give up (bounded boot time).
        # -cf = our scoped config; -lf/-pf keep eth1's lease + pid separate from
        # anything else on the box.
        dhclient -4 -1 \
            -cf "$DHCLIENT_LAB_CONF" \
            -lf "$DHCLIENT_LEASES" \
            -pf "$DHCLIENT_PID" \
            "$LAB_IF" >/dev/null 2>&1
        CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
        case "$CUR" in *"inet ${LAB_PREFIX}"*) HAVE_LAB_ADDR=1 ;; esac
    fi

    # ALWAYS scrub, whether or not we ran dhclient this boot: ifupdown may have
    # run its own dhclient before us.
    scrub_lab_default_route

    if [ "$HAVE_LAB_ADDR" -eq 0 ]; then
        # Documented fallback so the box is still workable when the lab's DHCP
        # service is deliberately crippled. Outside the pool, so it can never
        # collide with a real lease. NO gateway is added - the lab segment has
        # none, and adding one is forbidden.
        ip addr add "${B_FALLBACK_IP}/${LAB_CIDR}" dev "$LAB_IF" 2>/dev/null
        CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
        case "$CUR" in
            *"inet ${B_FALLBACK_IP}/"*)
                log "WARNING: no DHCP lease; applied documented static fallback ${B_FALLBACK_IP}/${LAB_CIDR}"
                ;;
            *)
                fail "no DHCP lease and static fallback could not be applied"
                ;;
        esac
    else
        log "${LAB_IF} has a ${LAB_PREFIX}x address"
    fi

    write_resolv_conf
    ;;

  *)
    log "ERROR: unknown role '$ROLE'"
    exit 2
    ;;
esac

mgmt_guard "post-baseline"
exit "$RC"
LAB4_NET_BODY
} > "$BASE_SCRIPT"
chmod 700 "$BASE_SCRIPT"

# Syntax-check the generated script before any unit is allowed to run it.
if ! bash -n "$BASE_SCRIPT"; then
    echo "ERROR: generated ${BASE_SCRIPT} failed syntax check - not enabling unit" >&2
    exit 6
fi
ok "generated ${BASE_SCRIPT} passes bash -n"

cat > "$BASE_UNIT_PATH" << EOF
[Unit]
Description=lab4-name-resolution baseline lab-segment config (eth1 / ${LAB_NET} only)
# network-online.target ALONE is not enough: with no *-wait-online unit enabled
# it is reached almost immediately and we would race ifupdown. Order explicitly
# against networking.service so ifupdown is finished before we touch eth1.
After=network-online.target networking.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BASE_SCRIPT} ${ROLE}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$BASE_UNIT_PATH"
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "$BASE_UNIT" >/dev/null 2>&1 || warn "could not enable ${BASE_UNIT}"

echo "[*] Applying baseline via ${BASE_SCRIPT} (same code path as boot) ..."
if bash "$BASE_SCRIPT" "$ROLE"; then
    ok "baseline applied"
else
    bad "baseline helper exited non-zero"
fi

# =============================================================================
# 13. Field ticket -> /root/FIELD_TICKET.txt and /etc/motd.
#     Kept BYTE-IDENTICAL to lab4-name-resolution/FIELD_TICKET.txt.
# =============================================================================
echo "[*] Installing field ticket ..."
cat > "$TICKET_FILE" << 'LAB_TICKET_EOF'
================================================================================
                 NORTHSTAR LOGISTICS - IT SERVICE DESK
                        FIELD DISPATCH TICKET
================================================================================

TICKET ID      : NSL-51907
OPENED         : 06:52 local
PRIORITY       : P2 - HIGH (Building 7 line control degraded, no data loss)
STATUS         : DISPATCHED - awaiting Field Application Engineer
QUEUE          : Network Operations -> Field Services
REPORTER       : Marcus Ibarra, Controls Technician - Building 7
CONTACT        : ext. 7712 / mibarra@northstar-logistics.example
ASSIGNED TO    : (you)

--------------------------------------------------------------------------------
AFFECTED SYSTEMS
--------------------------------------------------------------------------------
  Container-A   lab-dns-a    PLANT segment address 10.40.40.10
                             "Site services box" for Building 7. Per the
                             as-built binder this box provides the plant
                             segment's automatic addressing and its name
                             lookups.

  Container-B   lab-dns-b    PLANT segment address is NOT set by hand - it is
                             handed out automatically and should land somewhere
                             in 10.40.40.100 - 10.40.40.150. This is the box the
                             HMI package runs on.

  Both hosts sit on the isolated 10.40.40.0/24 plant segment. There is no router
  on that segment, there is no gateway on it, and nothing else is plugged into
  it. Everything the plant floor needs is either on Container-A or on the
  segment itself.

  Plant naming convention (copied verbatim from the Building 7 as-built binder,
  section 4.2 - "Addressing and Naming"):

      controller-a.plant.northstar.example      line controller, Building 7
      hmi.plant.northstar.example               operator terminal
      historian.plant.northstar.example         trend / batch archive
      packer-01.plant.northstar.example         end-of-line packer
      gateway.plant.northstar.example           reserved, not yet installed

--------------------------------------------------------------------------------
HOW TO CONNECT
--------------------------------------------------------------------------------
  Management access is UNAFFECTED and is confirmed working from the office
  network. Connect over the management addresses:

      ssh fae@192.168.10.206        (Container-A)
      ssh fae@192.168.10.207        (Container-B)

  Fallback console password is on file with the desk if key auth is not set up
  for your workstation. Do NOT reconfigure the management interface, its
  address, or the default route for any reason. It is the only remote path to
  these boxes, Building 7 is a badge-escort area, and the last shift that can
  let anyone in leaves at 15:30. Lose management and this ticket becomes a
  truck roll and the line stays down until tomorrow.

--------------------------------------------------------------------------------
USER COMPLAINT (verbatim from reporter)
--------------------------------------------------------------------------------
  "The HMI can't reach the controller by name any more.

  Our operator terminal software is configured with the names out of the binder,
  not with numbers - that is how the integrator set it up and we have never
  changed it. As of this morning every screen that talks to the controller is
  showing 'host not found' or just spinning until it gives up. The batch log
  stopped writing at 05:40.

  Here is the part I don't understand. If I get on Container-B and I type
  ping 10.40.40.10 with the numbers, it answers straight away, every single
  packet, no loss. If I type the name instead it does not work. Same box, same
  cable, same second. So the network is obviously fine, and the network team
  agrees - they say the switch is clean and there are no errors on the port.

  I tried the same thing with the operator terminal's own name and with the
  historian and I get the same kind of nothing. One of them I am fairly sure
  came back straight away saying it did not know the name, and another one just
  sat there for a while before it gave up, but I was jumping between two
  terminals and honestly I could not swear to which one did which.

  I can log into both boxes from my desk with no trouble at all the whole time,
  which is why I don't think anything is actually down.

  The only thing I know of that changed is that the vendor was on site Tuesday
  night and patched and rebooted the services box. It seemed fine Wednesday
  though, so I don't know if that is related."

--------------------------------------------------------------------------------
SYMPTOMS OBSERVED / TRIAGE ALREADY PERFORMED BY REPORTER
--------------------------------------------------------------------------------
  * From Container-B: ping by numeric address 10.40.40.10 -> 0% loss, replies
    normal. Reporter re-ran this several times and it was consistent.
  * From Container-B: anything that uses a Building 7 name -> fails.
  * Reporter's account of the exact error text is INCONSISTENT. He recalls at
    least one immediate "unknown host" style failure and at least one long
    hang. Do not rely on his recollection - reproduce it yourself and write
    down exactly what you see, per name and per tool. The difference between
    "answered immediately with nothing" and "never answered at all" matters.
  * Reporter rebooted BOTH containers. No change - the same behaviour came
    back after the reboot.
  * Reporter confirmed Container-B still has a plant segment address in the
    expected range and did not set it by hand.
  * Reporter power-cycled the plant segment switch. No change.
  * Network team checked the switch port counters - clean, no errors, no drops.
  * Vendor patched and rebooted Container-A on Tuesday night. Vendor states the
    patch was "operating system updates only" and that they changed no
    configuration. (Treat that claim with the usual amount of trust.)
  * No change ticket exists for Wednesday or Thursday.

--------------------------------------------------------------------------------
SCOPE OF WORK
--------------------------------------------------------------------------------
  1. Restore name-based access from Container-B for every Building 7 name in
     the as-built binder, so that looking up a name returns the address the
     binder says it should return, and so that the ordinary tools an
     application would use agree with each other.
  2. Confirm Container-B is still getting its plant segment address
     automatically from Container-A and has not been quietly hand-configured.
  3. Verify the fix survives a reboot of BOTH containers. The reporter already
     rebooted once and it did not help - if your fix does not persist, you will
     be back here tomorrow.
  4. Document root cause and the exact commands used, for the change record.

  OUT OF SCOPE / HARD CONSTRAINT: the management interface (192.168.10.206 /
  192.168.10.207), its address, and the default route must not be modified.
  Management must also keep working for ordinary things like package updates
  while you are working - do not trade one outage for another.

--------------------------------------------------------------------------------
NOTES
--------------------------------------------------------------------------------
  Assume the problem may be more than one thing, and assume more than one box
  is involved. The reporter is a controls technician, not a network engineer;
  his description reflects what he could see from the surface, and "it works
  with numbers but not with names" is the single most useful sentence in this
  ticket.

  Work the layers in order. Verify each layer before you move up one. Re-test
  after every single change, and re-test from the machine that is actually
  complaining, not only from the box you are logged into.

  When two tools disagree about the same question, that disagreement IS the
  evidence. Do not average it out.

================================================================================
                        END OF TICKET  -  NSL-51907
================================================================================
LAB_TICKET_EOF
chmod 644 "$TICKET_FILE"
cp "$TICKET_FILE" /etc/motd
chmod 644 /etc/motd

# =============================================================================
# 14. Prove the WORKING state.
#
#     The lab is not "built" because the config files exist. It is built when a
#     query actually returns the right answer. These probes are the acceptance
#     criteria; they run before the verification block so their results can feed
#     into it.
# =============================================================================
echo "[*] Proving the working state ..."

DIG_CTRL=""
DIG_HMI=""
GETENT_CTRL=""
LEASE_ADDR=""

if command -v dig >/dev/null 2>&1; then
    # +time/+tries bound the wait so a dead server does not stall the deploy.
    DIG_CTRL="$(dig +short +time=3 +tries=1 "@${DNS_SERVER}" "controller-a.${ZONE}" A 2>/dev/null | head -n1)"
    DIG_HMI="$(dig +short +time=3 +tries=1 "@${DNS_SERVER}" "hmi.${ZONE}" A 2>/dev/null | head -n1)"
fi
GETENT_CTRL="$(getent hosts "controller-a.${ZONE}" 2>/dev/null | awk '{print $1}' | head -n1)"
LEASE_ADDR="$(ip -4 -o addr show dev "$LAB_IF" 2>/dev/null | awk '{print $4}' | head -n1)"

echo "    dig @${DNS_SERVER} controller-a  -> ${DIG_CTRL:-<no answer>}"
echo "    dig @${DNS_SERVER} hmi           -> ${DIG_HMI:-<no answer>}"
echo "    getent hosts controller-a        -> ${GETENT_CTRL:-<no answer>}"
echo "    ${LAB_IF} address                -> ${LEASE_ADDR:-<none>}"

# =============================================================================
# 15. Verification
#
#     [FAIL] = the lab is not correctly built and must not be armed.
#     [WARN] = legitimately expected mid-deploy (e.g. role a checking things
#              that only exist once role b is built). Never affects exit code.
# =============================================================================
echo ""
echo "=== Verification ==="

MISSING=""
if [ "$ROLE" = "a" ]; then
    CHECK_BINS="dig dnsmasq tcpdump ping ss sudo iptables"
else
    CHECK_BINS="dig dhclient tcpdump ping ss sudo nc"
fi
for p in $CHECK_BINS; do
    command -v "$p" >/dev/null 2>&1 || MISSING="${MISSING} ${p}"
done
if [ -z "$MISSING" ]; then
    ok "diagnostic toolkit installed (${CHECK_BINS})"
else
    bad "missing binaries:${MISSING}"
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

# eth1 addressing
LAB_ADDR_OUT="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null || true)"
case "$LAB_ADDR_OUT" in
    *"inet ${LAB_PREFIX}"*) ok "${LAB_IF} has a ${LAB_PREFIX}x address (${LEASE_ADDR})" ;;
    *)                      bad "${LAB_IF} has no ${LAB_PREFIX}x address" ;;
esac

# eth1 must NOT have a gateway of its own.
LAB_DEF="$(ip -4 route show default 2>/dev/null || true)"
case "$LAB_DEF" in
    *"dev ${LAB_IF}"*) bad "a default route exists on ${LAB_IF} - the lab segment has no gateway" ;;
    *)                 ok "no default route on ${LAB_IF}" ;;
esac

# nsswitch ordering: fault 2's entire premise is that files beats dns.
case "$NSS_HOSTS_LINE" in
    *files*dns*) ok "nsswitch hosts order is files-before-dns" ;;
    *)           bad "nsswitch hosts order is not files-before-dns: ${NSS_HOSTS_LINE:-<none>}" ;;
esac

# resolv.conf must have BOTH the plant resolver and the site fallback, or the
# management path loses DNS while the lab is broken.
RESOLV="$(cat /etc/resolv.conf 2>/dev/null || true)"
case "$RESOLV" in
    *"nameserver ${DNS_SERVER}"*) ok "resolv.conf lists the plant resolver ${DNS_SERVER}" ;;
    *)                            bad "resolv.conf does not list ${DNS_SERVER}" ;;
esac
case "$RESOLV" in
    *"nameserver ${FALLBACK_DNS}"*) ok "resolv.conf keeps the ${FALLBACK_DNS} fallback (apt stays alive)" ;;
    *)                              bad "resolv.conf lost the ${FALLBACK_DNS} fallback" ;;
esac

# No fault residue anywhere.
if [ -e "$FAULT_UNIT_PATH" ] || [ -e "$FAULT_SCRIPT" ]; then
    bad "fault persistence artifacts still present"
else
    ok "fault persistence removed"
fi
if grep -q "$HOSTS_FAULT_TAG" /etc/hosts 2>/dev/null; then
    bad "/etc/hosts still contains a tagged fault entry"
else
    ok "/etc/hosts has no tagged fault entry"
fi
if [ -e "$CONF_CACHE" ]; then
    bad "${CONF_CACHE} still present (TTL fault residue)"
else
    ok "no TTL override file present"
fi

# Baseline persistence unit must be ENABLED.
#
# NOTE THE SHAPE OF THIS CHECK: `systemctl is-enabled` exits NON-ZERO for a
# disabled unit BY DESIGN. Piping it into grep under `set -o pipefail` inverts
# the result and reports a correctly-disabled unit as a command failure. Capture
# the value first, then compare the string.
BASE_ENABLED="$(systemctl is-enabled "$BASE_UNIT" 2>/dev/null || true)"
if [ "$BASE_ENABLED" = "enabled" ]; then
    ok "${BASE_UNIT} enabled (baseline survives reboot)"
else
    bad "${BASE_UNIT} is '${BASE_ENABLED:-unknown}', expected 'enabled'"
fi

if [ "$ROLE" = "a" ]; then
    if systemctl is-active --quiet dnsmasq; then
        ok "dnsmasq active"
    else
        bad "dnsmasq not active"
        systemctl status dnsmasq --no-pager -l 2>&1 | sed 's/^/       /'
    fi

    # Re-assert the socket safety property at the END too. The earlier check ran
    # right after the restart; this one runs after everything else has happened.
    SOCKETS2="$( { ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null; } || true )"
    SAFE=1
    case "$SOCKETS2" in *"${MGMT_IP}:53"*) SAFE=0 ;; esac
    case "$SOCKETS2" in *"${MGMT_IP}:67"*) SAFE=0 ;; esac
    case "$SOCKETS2" in *"0.0.0.0:53"*)    SAFE=0 ;; esac
    case "$SOCKETS2" in *"[::]:53"*)       SAFE=0 ;; esac
    if [ "$SAFE" -eq 1 ]; then
        ok "DHCP/DNS sockets are not on ${MGMT_IP} and not on a wildcard :53"
    else
        bad "dnsmasq socket exposure detected - the real LAN may be at risk"
        printf '%s\n' "$SOCKETS2" | sed 's/^/       /'
    fi

    # The server can answer its own query, which proves the zone is loaded.
    if [ "$DIG_CTRL" = "10.40.40.10" ]; then
        ok "dig @${DNS_SERVER} controller-a.${ZONE} -> 10.40.40.10"
    else
        bad "dig @${DNS_SERVER} controller-a.${ZONE} returned '${DIG_CTRL:-<nothing>}', expected 10.40.40.10"
    fi
    if [ "$DIG_HMI" = "10.40.40.50" ]; then
        ok "dig @${DNS_SERVER} hmi.${ZONE} -> 10.40.40.50"
    else
        bad "dig @${DNS_SERVER} hmi.${ZONE} returned '${DIG_HMI:-<nothing>}', expected 10.40.40.50"
    fi

    # Whether a client has a lease is not knowable from here until CT 207 is
    # built. WARN, never FAIL.
    if [ -f /var/lib/misc/dnsmasq.leases ] && [ -s /var/lib/misc/dnsmasq.leases ]; then
        ok "DHCP has issued at least one lease"
        sed 's/^/       /' /var/lib/misc/dnsmasq.leases
    else
        warn "no DHCP leases issued yet - expected until CT 207 (role b) is built"
    fi
fi

if [ "$ROLE" = "b" ]; then
    # This is the acceptance test that matters: the CLIENT can resolve the zone
    # from the server, and the resolver stack (getent) agrees with DNS (dig).
    if [ "$DIG_CTRL" = "10.40.40.10" ]; then
        ok "dig @${DNS_SERVER} controller-a.${ZONE} -> 10.40.40.10"
    else
        bad "dig @${DNS_SERVER} controller-a.${ZONE} returned '${DIG_CTRL:-<nothing>}', expected 10.40.40.10"
        echo "       (is CT 206 built and dnsmasq running?)"
    fi
    if [ "$DIG_HMI" = "10.40.40.50" ]; then
        ok "dig @${DNS_SERVER} hmi.${ZONE} -> 10.40.40.50"
    else
        bad "dig @${DNS_SERVER} hmi.${ZONE} returned '${DIG_HMI:-<nothing>}', expected 10.40.40.50"
    fi
    if [ "$GETENT_CTRL" = "10.40.40.10" ]; then
        ok "getent hosts controller-a.${ZONE} -> 10.40.40.10 (agrees with dig)"
    else
        bad "getent hosts controller-a.${ZONE} returned '${GETENT_CTRL:-<nothing>}', expected 10.40.40.10"
    fi

    # Lease vs fallback. Both are workable; only the fallback is noteworthy.
    LEASE_OK=0
    if [ -s "$DHCLIENT_LEASES" ]; then
        LEASE_OK=1
    fi
    case "$LAB_ADDR_OUT" in
        *"inet ${B_FALLBACK_IP}/"*)
            warn "${LAB_IF} is on the STATIC FALLBACK ${B_FALLBACK_IP} - DHCP did not answer."
            warn "expected only if CT 206 is not built yet or its DHCP service is down."
            ;;
        *)
            if [ "$LEASE_OK" -eq 1 ]; then
                ok "DHCP lease file present at ${DHCLIENT_LEASES}"
            else
                warn "no lease file at ${DHCLIENT_LEASES} (address may predate this run)"
            fi
            ;;
    esac

    # The DHCP client must not have smuggled in a resolver of its own.
    case "$RESOLV" in
        *"Managed by lab4-net.service"*) ok "resolv.conf is still lab-managed (dhclient did not rewrite it)" ;;
        *)                               bad "resolv.conf was rewritten by something else - check the dhclient hook" ;;
    esac
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

# Final, mandatory. Runs before the exit decision so the lifeline is always
# asserted regardless of how everything above went.
mgmt_guard "post-setup final"

echo ""
if [ "$VERIFY_FAILED" -eq 0 ]; then
    echo "=============================================================="
    echo " Setup complete for role '${ROLE}'. Baseline is the WORKING state."
    echo " Arm the lab with: bash /root/break.sh ${ROLE}"
    echo " Reset at any time by re-running: bash /root/setup.sh ${ROLE}"
    echo "=============================================================="
    exit 0
else
    echo "=============================================================="
    echo " Setup for role '${ROLE}' finished with FAILURES (see [FAIL] above)."
    echo " Do NOT arm the lab until they are resolved - a learner cannot tell"
    echo " a broken lab from a hard exercise."
    echo "=============================================================="
    exit 1
fi
