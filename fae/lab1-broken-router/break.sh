#!/bin/bash
# =============================================================================
# lab1-broken-router :: break.sh   (FAULT SET v2)
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
# -----------------------------------------------------------------------------
# WHY v2 EXISTS
# -----------------------------------------------------------------------------
# The v1 fault set (preserved as break-v1.sh) was built entirely out of
# `ip addr` / `ip route` / `ip neigh` - a /28 netmask mismatch, a bogus next-hop
# and a poisoned permanent ARP entry. The learner has solved it AND read the
# solutions, so those three tools are spent as discovery paths.
#
# v2 deliberately makes all three of those commands read PERFECTLY while the
# segment is dead. Every v2 fault lives in a subsystem that `ip` does not show:
# netfilter, the reverse-path-filter sysctls + policy routing, and the traffic
# control (qdisc) layer. The whole point is to break the reflex of "ip a, ip r,
# ip n, must be fine then".
#
# -----------------------------------------------------------------------------
# FAULT DISTRIBUTION
# -----------------------------------------------------------------------------
#   role b (CT 202) -> faults 1 and 2
#   role a (CT 201) -> fault 3
#
#   Fault 1 (B, discovered with `nft list ruleset` / `iptables -S`)
#           A netfilter rule DROPs ICMP echo-request arriving on eth1 from the
#           lab subnet. TCP is untouched, so sshd on 10.10.10.20:22 answers
#           normally. This is the highest-value lesson in the whole lab:
#           *ping failing does not mean the network is down*. The learner is
#           expected to find that `nc -vz 10.10.10.20 22` SUCCEEDS while ping
#           to the same address fails, and to trust the TCP result.
#           `ip addr`, `ip route` and `ip neigh` on B are all pristine.
#
#   Fault 2 (B, discovered with `dmesg` / `journalctl -k` + `sysctl -a`)
#           Strict reverse-path filtering (rp_filter=1 on all AND on eth1) plus
#           a policy-routing rule that makes the REVERSE lookup for A's address
#           resolve out the wrong device. Packets from 10.10.10.10 arriving on
#           eth1 are dropped by the kernel before any socket or firewall
#           decision, and log_martians=1 leaves the evidence in the kernel ring
#           buffer ("martian source 10.10.10.10"). That log line is the intended
#           discovery path.
#
#           IMPLEMENTATION NOTE (read this before "simplifying" it):
#           the obvious way to fail RPF is to plant a more-specific 10.10.10.10/32
#           route in the MAIN table pointing at a dummy/blackhole device. That
#           works - but it is visible in `ip route`, which is exactly the v1
#           discovery path we are retiring, and it also breaks B's FORWARD path
#           to A, which muddies the symptom. Instead the /32 lives in its own
#           routing table (100), selected by an `ip rule` whose selector is
#           `iif eth1`. Input/forward lookups for traffic arriving on eth1 hit
#           it; locally generated traffic (output lookups) never does, because
#           output lookups do not carry an ingress interface. Result:
#             - B -> A still works (main table, connected route, untouched)
#             - A -> B is dropped at ingress by RPF
#             - `ip route` / `ip route get 10.10.10.10` on B look perfect
#           Table 100 contains exactly one route, so there is nothing for the
#           kernel to arbitrate: the behaviour is identical on every reset.
#
#   Fault 3 (A, discovered with `tc qdisc show dev eth1`)
#           A netem qdisc on A's eth1 discards 100% of EGRESS. A's addressing,
#           routing and neighbour table are all correct, the interface is UP,
#           counters look plausible - and nothing leaves the box. tcpdump on A
#           does not even show the outbound packets, because the AF_PACKET
#           egress tap sits AFTER the qdisc dequeue and netem drops on enqueue.
#           This is the tool nobody thinks to check.
#
# -----------------------------------------------------------------------------
# INTENDED DISCOVERY ORDER (each layer must be peeled to expose the next)
# -----------------------------------------------------------------------------
#   Stage 0  Symptom: ping fails in BOTH directions.
#            A->B: nothing ever leaves A (fault 3).
#            B->A: B's request reaches A, A builds a reply, the reply is
#                  discarded on A's egress (fault 3 again).
#            So fault 3 is the outermost layer and masks the other two.
#
#   Stage 1  Learner captures on both ends, sees B's requests arriving at A and
#            NOTHING leaving A, checks `tc qdisc show dev eth1` -> fault 3.
#            Fix it. Now B -> A ping works. A -> B ping still fails.
#
#   Stage 2  A's traffic now reaches B and vanishes. tcpdump on B SEES the echo
#            requests arrive (they are dropped after the tap, in the routing
#            input path), yet nothing is delivered and nothing is replied.
#            `dmesg -T | grep -i martian` names the source address -> fault 2.
#            Fix it. Now A -> B TCP works, A -> B ping still fails.
#
#   Stage 3  The payoff: `nc -vz 10.10.10.20 22` from A succeeds while ping to
#            the same address fails, and B -> A ping works (an echo REPLY is not
#            an echo-request, so it is never matched by the rule).
#            `nft list ruleset` on B -> fault 1.
#
#   Each stage uses a different tool. None of the three primary tools is
#   `ip addr`, `ip route` or `ip neigh`.
#
# -----------------------------------------------------------------------------
# *** SACRED INVARIANT ***
# -----------------------------------------------------------------------------
#   eth0, its IP, and the default route via 192.168.10.1 are the learner's SSH
#   lifeline over Tailscale, from a travel laptop, with no console. NOTHING here
#   may modify them.
#     - There is no `ip route add default` / `ip route del default` in this file
#       or in the persistence script it generates. Not even a scoped one.
#     - Every fault names eth1, the 10.10.10.0/24 prefix, or a routing table
#       reached only by an `iif eth1` rule.
#     - The netfilter table's FIRST two rules unconditionally ACCEPT anything
#       arriving on eth0 and anything sourced from 192.168.10.0/24, before any
#       drop rule is evaluated. Belt and braces: even a botched later rule
#       cannot take SSH down.
#     - rp_filter is set globally (conf.all), which does apply to eth0 as well.
#       That is SAFE here and the reason is worth stating: strict RPF asks
#       "would I route back to this packet's source out the interface it came
#       in on?". eth0 owns the one and only default route, so the reverse lookup
#       for ANY off-subnet source (including the 100.64.0.0/10 tailnet address a
#       Tailscale-originated SSH session carries, since the subnet router does
#       not SNAT) resolves to eth0 and passes. On-subnet 192.168.10.x sources
#       resolve to eth0's connected route and pass. The fault only bites on eth1
#       because only eth1 has the poisoned reverse lookup. The generated script
#       still PROVES this at runtime (see rpf_sanity) and automatically reverts
#       rp_filter if the proof fails.
#     - The script ends with a MGMT GUARD that hard-fails if the eth0 address is
#       wrong or if there is anything other than exactly one default route via
#       192.168.10.1 dev eth0. The guard is built from captured variables and
#       `case`, never from a pipeline into `grep -q` - under `set -o pipefail` a
#       pipeline's exit status can be inverted by an upstream failure and a
#       guard that cannot fail is worse than no guard.
#   The persistence unit runs the same guard on every boot, so the invariant
#   holds unattended too.
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
        HOSTNAME_EXPECTED="lab-router-a"
        FAULTS_APPLIED="3"
        ;;
    b)
        MGMT_IP="192.168.10.202"
        HOSTNAME_EXPECTED="lab-router-b"
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

FAULT_SCRIPT="/usr/local/sbin/lab-faults-v2.sh"
FAULT_UNIT="lab-faults-v2.service"
UNIT_PATH="/etc/systemd/system/${FAULT_UNIT}"

# v1 artefacts. If this container was previously armed with the v1 fault set its
# unit is still enabled and would re-inject the OLD faults on the next boot,
# silently turning a clean v2 lab into a six-fault mess. Remove them.
V1_SCRIPT="/usr/local/sbin/lab-faults.sh"
V1_UNIT="lab-faults.service"
V1_UNIT_PATH="/etc/systemd/system/${V1_UNIT}"

# =============================================================================
# MGMT GUARD - the single most important function in this repo.
#
# Asserts that eth0 still holds the expected 192.168.10.20X address AND that
# there is EXACTLY ONE default route and it is via 192.168.10.1 dev eth0.
#
# Read-only by design: it never repairs anything, because a guard that mutates
# state can mask the very bug it exists to catch.
#
# Built from captured strings + `case`, NOT from `... | grep -q`. With
# `set -o pipefail` a pipeline reports the failure of ANY member, so a
# `cmd | grep -q x` guard can report failure for reasons unrelated to the match
# (or, with the sense inverted by a `!`, report success). Capture, then test.
# =============================================================================
mgmt_guard() {
    local ctx="${1:-}"
    local addr_out def_out line
    local addr_ok=0 route_ok=0 def_count=0

    addr_out="$(ip -4 -o addr show dev "$MGMT_IF" 2>/dev/null)"
    case "$addr_out" in
        *"inet ${MGMT_IP}/"*) addr_ok=1 ;;
    esac

    def_out="$(ip -4 route show default 2>/dev/null)"
    while IFS= read -r line; do
        [ -n "$line" ] && def_count=$((def_count + 1))
    done <<< "$def_out"

    # Exactly one default route, and it must name BOTH the gateway and eth0 -
    # a default out of some other interface must not be able to satisfy this.
    if [ "$def_count" -eq 1 ]; then
        case "$def_out" in
            *"via ${MGMT_GW} dev ${MGMT_IF}"*) route_ok=1 ;;
        esac
    fi

    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ]; then
        echo "[OK]   MGMT GUARD${ctx:+ (${ctx})}: ${MGMT_IF} holds ${MGMT_IP}, exactly one default via ${MGMT_GW}"
        return 0
    fi

    echo ""
    echo "################################################################"
    echo "#                                                              #"
    echo "#   FAIL - MANAGEMENT LIFELINE COMPROMISED                     #"
    echo "#                                                              #"
    echo "################################################################"
    echo "#  Context      : ${ctx:-final check}"
    echo "#  Expected addr: ${MGMT_IF} = ${MGMT_IP}/24  -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    echo "#  Expected rt  : exactly 1 default via ${MGMT_GW} dev ${MGMT_IF} -> $([ "$route_ok" -eq 1 ] && echo OK || echo WRONG)"
    echo "#  Default routes seen: ${def_count}"
    echo "################################################################"
    echo ""
    echo "--- ${MGMT_IF} addresses ---"
    ip -4 addr show dev "$MGMT_IF" 2>/dev/null || echo "(none)"
    echo "--- default routes ---"
    printf '%s\n' "${def_out:-(none)}"
    echo ""
    echo "DO NOT continue. Restore management access from the Proxmox console:"
    echo "    pct exec <CTID> -- ip addr add ${MGMT_IP}/24 dev ${MGMT_IF}"
    echo "    pct exec <CTID> -- ip route add default via ${MGMT_GW} dev ${MGMT_IF}"
    echo ""
    exit 1
}

echo "=============================================================="
echo " lab1-broken-router break (fault set v2) :: role=${ROLE}"
echo "=============================================================="

# =============================================================================
# 0. IDENTITY - fail fast, BEFORE writing anything.
#
# `break.sh a` fired at CT 202 would arm the wrong faults on the wrong box and
# leave the lab unsolvable. The hostname is the cheapest independent signal that
# we are where we think we are; the mgmt guard below cross-checks the address.
# Escape hatch for a legitimately-renamed container: LAB_FORCE_ROLE=1.
# =============================================================================
CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_EXPECTED" ]; then
    if [ "${LAB_FORCE_ROLE:-0}" = "1" ]; then
        echo "    WARNING: hostname '${CURRENT_HOSTNAME}' != '${HOSTNAME_EXPECTED}' (forced by LAB_FORCE_ROLE=1)"
    else
        echo "ERROR: hostname is '${CURRENT_HOSTNAME}' but role '${ROLE}' expects '${HOSTNAME_EXPECTED}'." >&2
        echo "       Refusing to inject faults into a container I cannot positively identify." >&2
        echo "       role a = CT 201 (lab-router-a), role b = CT 202 (lab-router-b)." >&2
        echo "       Override deliberately with: LAB_FORCE_ROLE=1 $0 ${ROLE}" >&2
        exit 2
    fi
else
    echo "    identity OK: hostname ${CURRENT_HOSTNAME} matches role ${ROLE}"
fi

# Pre-flight: refuse to touch anything if the lifeline is already wrong. This
# also confirms the mgmt ADDRESS matches the role, catching a hostname that was
# set by hand on the wrong box.
mgmt_guard "pre-flight"

if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
    echo "ERROR: ${LAB_IF} not present - run setup.sh first and check the CT's vmbr1 NIC" >&2
    exit 3
fi

# Paranoia: the lab interface must not be the lifeline. If the CT's NICs were
# built in the wrong order, eth1 IS management and a netfilter/qdisc fault on it
# is a lockout.
LAB_ADDR_OUT="$(ip -4 -o addr show dev "$LAB_IF" 2>/dev/null)"
case "$LAB_ADDR_OUT" in
    *"inet 192.168.10."*)
        echo "ERROR: ${LAB_IF} carries a 192.168.10.x address - that is the management" >&2
        echo "       subnet. The CT's NICs appear mis-mapped. Refusing to inject." >&2
        exit 3
        ;;
esac

# =============================================================================
# 1. PACKAGES
#
# setup.sh installs the baseline toolkit but not netfilter tooling and not nc.
# Both are needed here:
#   - nftables (or iptables) is the mechanism for fault 1
#   - netcat-openbsd is the learner's TCP prove-it tool; without it the central
#     lesson of fault 1 ("ping is not connectivity") has no instrument.
#
# Non-interactive, retried, and tolerant of a slow mirror. Nothing below is
# fatal on its own - the backend probe in step 2 decides what we can actually
# build the fault out of.
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -qq -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120"

apt_install() {
    # $@ = package names. Returns 0 if apt reported success on either attempt.
    # shellcheck disable=SC2086
    if apt-get install $APT_OPTS "$@" >/dev/null 2>&1; then
        return 0
    fi
    echo "    apt install failed for: $* - refreshing indexes and retrying ..."
    apt-get update -qq -o Acquire::Retries=3 >/dev/null 2>&1
    # shellcheck disable=SC2086
    apt-get install $APT_OPTS "$@" >/dev/null 2>&1
}

echo "[*] Installing fault + diagnostic packages ..."
apt_install netcat-openbsd || echo "    WARNING: netcat-openbsd unavailable (learner loses the TCP prove-it tool)"

FW_BACKEND="none"
if [ "$ROLE" = "b" ]; then
    apt_install nftables || echo "    WARNING: nftables package not installed"
    # Probe for real usability, not just for the binary. nf_tables is netns
    # aware and needs host modules; a privileged CT usually has it, but if the
    # probe fails we fall back to iptables rather than shipping a dead fault.
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        FW_BACKEND="nft"
    else
        echo "    nftables not usable in this container - falling back to iptables"
        apt_install iptables || echo "    WARNING: iptables package not installed"
        if command -v iptables >/dev/null 2>&1 && iptables -S >/dev/null 2>&1; then
            FW_BACKEND="iptables"
        fi
    fi
    if [ "$FW_BACKEND" = "none" ]; then
        echo "ERROR: neither nftables nor iptables is usable inside this container." >&2
        echo "       Fault 1 cannot be built. Check that the host has nf_tables /" >&2
        echo "       ip_tables modules loaded and that CT ${MGMT_IP##*.} is privileged." >&2
        exit 4
    fi
    echo "    firewall backend: ${FW_BACKEND}"
fi

# =============================================================================
# 2. Retire the v1 persistence unit (scoped, idempotent).
#
# Only removes artefacts THIS repo created. Nothing else on the box is touched.
# =============================================================================
echo "[*] Retiring any v1 fault persistence ..."
systemctl disable --now "$V1_UNIT" >/dev/null 2>&1
if [ -f "$V1_UNIT_PATH" ]; then
    rm -f "$V1_UNIT_PATH"
    echo "    removed ${V1_UNIT}"
fi
rm -f "$V1_SCRIPT"
systemctl daemon-reload >/dev/null 2>&1

# =============================================================================
# 3. Generate the persistence script.
#
# The SAME script both applies the faults now and re-applies them at boot, so
# there is exactly one definition of each fault and apply/persist cannot drift.
# The ticket asks the learner to prove their fix survives a reboot; a reboot
# must therefore NOT quietly repair the lab.
#
# The generated script carries its own copy of the MGMT GUARD so the invariant
# is enforced on every unattended boot, not only when a human runs break.sh.
# =============================================================================
echo "[*] Writing persistence script ${FAULT_SCRIPT} ..."
mkdir -p "$(dirname "$FAULT_SCRIPT")"

{
    echo '#!/bin/bash'
    echo '# GENERATED BY break.sh (fault set v2) - lab1-broken-router persistence.'
    echo '# Re-applies the lab faults at boot. Scoped to eth1 / 10.10.10.0/24 ONLY.'
    echo '# Never touches eth0, its address, or the default route.'
    echo "ROLE_DEFAULT=\"${ROLE}\""
    echo "MGMT_IP=\"${MGMT_IP}\""
    echo "FW_BACKEND=\"${FW_BACKEND}\""
    cat << 'LAB_FAULTS_BODY'
set -uo pipefail

# The role is baked in at generation time, but an explicit argument wins so the
# script behaves as its own command line advertises (systemd passes it too).
ROLE="${1:-$ROLE_DEFAULT}"

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
LAB_NET="10.10.10.0/24"
MGMT_NET="192.168.10.0/24"
PEER_A="10.10.10.10"
PEER_B="10.10.10.20"

# Fault 1 objects
NFT_TABLE="plant_filter"
NFT_CHAIN="plant_in"
IPT_CHAIN="PLANT_FILTER"

# Fault 2 objects
RPF_TABLE="100"          # dedicated routing table, reached only via the rule below
RPF_PREF="100"           # ip rule priority
RPF_MARK="0x64"          # skb mark; RPF honours marks, but NOT iif-keyed rules
RPF_MANGLE_TABLE="lab_mangle"   # nft table that sets the mark (iptables is absent)
SYSCTL_DECOY="/etc/sysctl.d/60-plant-net.conf"
SYSCTL_LATE="/etc/sysctl.d/99-zz-plant-hardening.conf"

RC=0
log()  { echo "lab-faults-v2[$ROLE]: $*"; }
fail() { log "ERROR: $*"; RC=1; }

# --- MGMT GUARD (identical contract to break.sh's) ---------------------------
# Captured strings + `case`, never a pipeline into grep -q. Requires EXACTLY one
# default route, via the mgmt gateway, out of the mgmt interface.
mgmt_guard() {
    local ctx="${1:-}"
    local addr_out def_out line
    local addr_ok=0 route_ok=0 def_count=0

    addr_out="$(ip -4 -o addr show dev "$MGMT_IF" 2>/dev/null)"
    case "$addr_out" in
        *"inet ${MGMT_IP}/"*) addr_ok=1 ;;
    esac

    def_out="$(ip -4 route show default 2>/dev/null)"
    while IFS= read -r line; do
        [ -n "$line" ] && def_count=$((def_count + 1))
    done <<< "$def_out"

    if [ "$def_count" -eq 1 ]; then
        case "$def_out" in
            *"via ${MGMT_GW} dev ${MGMT_IF}"*) route_ok=1 ;;
        esac
    fi

    if [ "$addr_ok" -eq 1 ] && [ "$route_ok" -eq 1 ]; then
        log "MGMT GUARD OK${ctx:+ ($ctx)}"
        return 0
    fi

    log "########################################################"
    log "#  FAIL - MANAGEMENT LIFELINE COMPROMISED (${ctx:-final})"
    log "#  ${MGMT_IF}=${MGMT_IP} -> $([ "$addr_ok" -eq 1 ] && echo PRESENT || echo MISSING)"
    log "#  exactly-one default via ${MGMT_GW} dev ${MGMT_IF} -> $([ "$route_ok" -eq 1 ] && echo OK || echo WRONG) (${def_count} default route(s))"
    log "########################################################"
    exit 1
}

# =============================================================================
# BOOT-ORDERING SAFETY
#
# In LXC, eth1 EXISTS from container start, so waiting for the LINK to appear
# buys nothing and we would race ifupdown. Wait for the interface to actually
# carry a lab ADDRESS, which only happens once ifupdown has finished with it.
# (v2 does not change eth1's address, but fault 3's qdisc and fault 2's routing
# rule are still cleaner to install against a settled interface, and a rule
# referencing eth1 before it is configured is a silent no-op waiting to happen.)
# =============================================================================
LAB_READY=0
for i in $(seq 1 30); do
    LAB_NOW="$(ip -4 -o addr show dev "$LAB_IF" 2>/dev/null)"
    case "$LAB_NOW" in
        *"inet 10.10.10."*) LAB_READY=1; break ;;
    esac
    sleep 1
done
if [ "$LAB_READY" -ne 1 ]; then
    if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
        log "ERROR: $LAB_IF never appeared; aborting without changes"
        exit 1
    fi
    log "WARNING: $LAB_IF has no 10.10.10.x address after 30s; injecting anyway"
fi

# Defensive: never operate on the management interface, whatever the constants
# say. Cheap, and it makes a future copy-paste edit fail loudly instead of
# quietly locking someone out.
if [ "$LAB_IF" = "$MGMT_IF" ]; then
    log "ERROR: LAB_IF == MGMT_IF - refusing to inject"
    exit 1
fi

mgmt_guard "pre-inject"

# =============================================================================
# FAULT 1 (role b) - ICMP echo-request filtered on the lab interface, TCP not.
#
# Discovery tool: `nft list ruleset`  (or `iptables -S` on the fallback path)
#
# Rule order is a safety property, not a style choice: the first two rules
# ACCEPT everything arriving on the management interface and everything sourced
# from the management subnet, and they are evaluated BEFORE the drop. Even if
# the drop rule were mis-typed into something broader, SSH survives.
#
# Only echo-REQUEST is dropped. Echo-replies are not matched, so B pinging A
# keeps working - which is the asymmetry that makes the learner stop and think.
# =============================================================================
apply_fault_1() {
    local out=""

    if [ "$FW_BACKEND" = "nft" ]; then
        # Dedicated table so we own our rules completely and `delete table` is a
        # clean, idempotent reset that cannot disturb anything else.
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1
        if ! nft -f - << NFT_RULES 2>/dev/null
table inet ${NFT_TABLE} {
    chain ${NFT_CHAIN} {
        type filter hook input priority 0; policy accept;

        # --- management lifeline, always first, always accept ---
        iifname "${MGMT_IF}" accept
        ip saddr ${MGMT_NET} accept

        # --- the fault: lab-segment echo-requests only ---
        iifname "${LAB_IF}" ip saddr ${LAB_NET} icmp type echo-request drop
    }
}
NFT_RULES
        then
            fail "could not load nft table ${NFT_TABLE}"
            return 1
        fi
        out="$(nft list table inet "$NFT_TABLE" 2>/dev/null)"
    else
        # iptables fallback. Custom chain jumped from INPUT position 1; INPUT's
        # policy is left alone (ACCEPT) so nothing else changes behaviour.
        iptables -N "$IPT_CHAIN" >/dev/null 2>&1
        iptables -F "$IPT_CHAIN" >/dev/null 2>&1
        iptables -A "$IPT_CHAIN" -i "$MGMT_IF" -j RETURN >/dev/null 2>&1
        iptables -A "$IPT_CHAIN" -s "$MGMT_NET" -j RETURN >/dev/null 2>&1
        iptables -A "$IPT_CHAIN" -i "$LAB_IF" -s "$LAB_NET" \
                 -p icmp --icmp-type echo-request -j DROP >/dev/null 2>&1
        if ! iptables -C INPUT -j "$IPT_CHAIN" >/dev/null 2>&1; then
            iptables -I INPUT 1 -j "$IPT_CHAIN" >/dev/null 2>&1
        fi
        out="$(iptables -S "$IPT_CHAIN" 2>/dev/null)"
    fi

    # Postcondition: the drop rule must actually be present.
    case "$out" in
        *echo-request*|*"--icmp-type 8"*) : ;;
        *) fail "fault 1 did NOT take - no echo-request drop rule found (${FW_BACKEND})"; return 1 ;;
    esac

    # The whole lesson depends on TCP still answering on the LAB address, so
    # make sure sshd is actually up and listening. If this is not true the
    # learner tests TCP, sees it fail too, and learns the wrong thing.
    if ! systemctl is-active --quiet ssh; then
        systemctl start ssh >/dev/null 2>&1
    fi
    local listen
    listen="$(ss -ltn 2>/dev/null)"
    # ss pads its columns, so ":22 " (with the trailing space) matches
    # "0.0.0.0:22" / "[::]:22" without also matching ":2222".
    case "$listen" in
        *":22 "*) : ;;
        *) fail "sshd is not listening on :22 - the TCP-still-works proof is broken"; return 1 ;;
    esac

    log "fault 1 applied"
    return 0
}

# =============================================================================
# FAULT 2 (role b) - strict reverse-path filtering drops A's traffic at ingress.
#
# Discovery tool: `dmesg -T` / `journalctl -k` (martian source) + `sysctl -a`
#
# Three parts:
#   1. rp_filter=1 (strict) on conf.all AND conf.eth1. The kernel uses
#      max(all, dev), so conf.all alone would be enough - both are set because
#      a learner who only clears the per-device knob must still see it fail.
#   2. log_martians=1 so the drop leaves evidence. Without this the fault is
#      invisible and the lab becomes guesswork, not diagnosis.
#   3. A policy-routing rule `iif eth1 lookup 100` plus a single route in table
#      100 sending A's address out `lo`. The reverse-path lookup for a packet
#      arriving on eth1 from 10.10.10.10 therefore resolves to lo, not eth1,
#      and the packet is dropped as a martian.
#
# Why the /32 is NOT in the main table: that would be an `ip route` fault (the
# v1 discovery path) and would also break B's forward path to A. Confined to
# table 100 behind an `iif` selector, it is invisible to `ip route`,
# `ip route get`, and to every locally originated packet - output lookups carry
# no ingress interface, so the rule never matches them. B -> A still works.
#
# Determinism: table 100 holds exactly one route. There is no competing entry
# for the kernel to arbitrate, so the behaviour is byte-identical on every reset.
#
# MANAGEMENT SAFETY: see the long note at the top of break.sh. rpf_sanity()
# below proves the reverse lookup for off-subnet sources still resolves to eth0
# and REVERTS rp_filter if it does not.
# =============================================================================
rpf_revert() {
    sysctl -w net.ipv4.conf.all.rp_filter=0        >/dev/null 2>&1
    sysctl -w "net.ipv4.conf.${LAB_IF}.rp_filter=0" >/dev/null 2>&1
    rm -f "$SYSCTL_LATE"
    while ip rule del pref "$RPF_PREF" >/dev/null 2>&1; do :; done
    ip route flush table "$RPF_TABLE" >/dev/null 2>&1
    nft delete table ip "$RPF_MANGLE_TABLE" >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null 2>&1
}

rpf_sanity() {
    # Simulate what strict RPF will ask on the management path: for an arbitrary
    # off-subnet source, and for an on-subnet source, does the lookup resolve to
    # eth0? If yes, SSH (LAN or tailnet-sourced) passes RPF.
    local off on
    off="$(ip route get 100.100.100.100 2>/dev/null)"
    on="$(ip route get "${MGMT_GW}" 2>/dev/null)"
    case "$off" in *"dev ${MGMT_IF}"*) : ;; *) return 1 ;; esac
    case "$on"  in *"dev ${MGMT_IF}"*) : ;; *) return 1 ;; esac
    return 0
}

apply_fault_2() {
    # --- the decoy ------------------------------------------------------------
    # The "obvious" file. It says the right thing. Fixing it and rebooting does
    # NOT fix the box, because 99-zz-* sorts after it and wins. This is the
    # non-obvious-file lesson: sysctl drop-ins are last-writer-wins by filename
    # order, so `grep -rn rp_filter /etc/sysctl.d/ /etc/sysctl.conf` is the
    # command that actually settles it.
    cat > "$SYSCTL_DECOY" << 'DECOY_EOF'
# Northstar Logistics - plant segment host tuning
# Standard build. Reverse-path filtering is intentionally relaxed on plant
# hosts because the process segment carries asymmetric telemetry.
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.all.log_martians = 0
DECOY_EOF
    chmod 644 "$SYSCTL_DECOY"

    # --- the file that actually wins -----------------------------------------
    # NOTE: the per-device (eth1) keys here are a no-op at systemd-sysctl time,
    # because that runs before eth1 exists. They are written anyway for honesty,
    # and this script re-applies them live after eth1 is up. conf.all.rp_filter
    # DOES apply at boot, and max(all,dev) means it alone is sufficient.
    cat > "$SYSCTL_LATE" << LATE_EOF
# Applied after the standard plant profile.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.${LAB_IF}.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.${LAB_IF}.log_martians = 1
LATE_EOF
    chmod 644 "$SYSCTL_LATE"

    # --- live application -----------------------------------------------------
    sysctl -w net.ipv4.conf.all.rp_filter=1            >/dev/null 2>&1
    sysctl -w "net.ipv4.conf.${LAB_IF}.rp_filter=1"    >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.log_martians=1         >/dev/null 2>&1
    sysctl -w "net.ipv4.conf.${LAB_IF}.log_martians=1" >/dev/null 2>&1

    # --- the poisoned reverse lookup -----------------------------------------
    # Delete-then-add at a known priority keeps this idempotent. The loop is
    # required because repeated `ip rule add` would stack duplicates.
    # Mark ingress packets from the peer, then key the policy rule on the MARK.
    # An `iif`-keyed rule is invisible to strict RPF (see header note); a fwmark
    # rule is honoured because __fib_validate_source() sets
    # fl4.flowi4_mark = IN_DEV_SRC_VMARK(idev) ? skb->mark : 0.
    sysctl -w net.ipv4.conf.all.src_valid_mark=1        >/dev/null 2>&1
    sysctl -w "net.ipv4.conf.${LAB_IF}.src_valid_mark=1" >/dev/null 2>&1
    nft add table ip "$RPF_MANGLE_TABLE" 2>/dev/null
    nft add chain ip "$RPF_MANGLE_TABLE" prerouting         "{ type filter hook prerouting priority -150 ; policy accept ; }" 2>/dev/null
    nft list table ip "$RPF_MANGLE_TABLE" 2>/dev/null | grep -q "meta mark set"         || nft add rule ip "$RPF_MANGLE_TABLE" prerouting              iifname "$LAB_IF" ip saddr "$PEER_A" meta mark set "$RPF_MARK" 2>/dev/null
    if ! nft list table ip "$RPF_MANGLE_TABLE" 2>/dev/null | grep -q "meta mark set"; then
        fail "could not install the nft mark rule (table ${RPF_MANGLE_TABLE})"
        return 1
    fi

    while ip rule del pref "$RPF_PREF" >/dev/null 2>&1; do :; done
    if ! ip rule add pref "$RPF_PREF" fwmark "$RPF_MARK" lookup "$RPF_TABLE" 2>/dev/null; then
        fail "could not install ip rule (pref ${RPF_PREF}, fwmark ${RPF_MARK})"
        return 1
    fi
    ip route flush table "$RPF_TABLE" >/dev/null 2>&1
    if ! ip route replace "${PEER_A}/32" dev lo table "$RPF_TABLE" 2>/dev/null; then
        fail "could not install ${PEER_A}/32 dev lo in table ${RPF_TABLE}"
        return 1
    fi

    # --- postconditions -------------------------------------------------------
    local v rules rt
    v="$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)"
    [ "$v" = "1" ] || { fail "fault 2: conf.all.rp_filter is '${v}', expected 1"; return 1; }
    v="$(cat "/proc/sys/net/ipv4/conf/${LAB_IF}/rp_filter" 2>/dev/null)"
    [ "$v" = "1" ] || { fail "fault 2: conf.${LAB_IF}.rp_filter is '${v}', expected 1"; return 1; }
    v="$(cat "/proc/sys/net/ipv4/conf/${LAB_IF}/log_martians" 2>/dev/null)"
    [ "$v" = "1" ] || { fail "fault 2: conf.${LAB_IF}.log_martians is '${v}', expected 1"; return 1; }

    rules="$(ip rule show 2>/dev/null)"
    case "$rules" in
        *"fwmark ${RPF_MARK} lookup ${RPF_TABLE}"*|*"fwmark 0x64 lookup ${RPF_TABLE}"*) : ;;
        *) fail "fault 2: fwmark policy rule -> table ${RPF_TABLE} missing"; return 1 ;;
    esac

    rt="$(ip route show table "$RPF_TABLE" 2>/dev/null)"
    case "$rt" in
        *"${PEER_A} dev lo"*) : ;;
        *) fail "fault 2: table ${RPF_TABLE} does not send ${PEER_A} to lo (got: ${rt})"; return 1 ;;
    esac

    # --- management safety proof ---------------------------------------------
    if ! rpf_sanity; then
        fail "fault 2: RPF sanity check FAILED - reverse lookup for an off-subnet source does not resolve to ${MGMT_IF}. Reverting rp_filter."
        rpf_revert
        return 1
    fi

    log "fault 2 applied"
    return 0
}

# =============================================================================
# FAULT 3 (role a) - egress qdisc silently discards everything on eth1.
#
# Discovery tool: `tc qdisc show dev eth1`  (`tc -s qdisc show dev eth1` for the
# drop counters)
#
# netem with loss 100% drops on ENQUEUE, which is upstream of the AF_PACKET
# egress tap - so tcpdump on A does not even see the packets it is "sending".
# `ip addr`, `ip route`, `ip neigh` and `ip link` all read correct. Even the
# neighbour entry for the peer going FAILED is a downstream symptom (A's ARP
# requests are dropped by the same qdisc), not the cause - a deliberate red
# herring pointing at layer 2.
#
# Scoped to eth1. eth0 is never named here; touching its qdisc would throttle
# the SSH lifeline.
#
# Fallback: sch_netem is a module and a container cannot modprobe. If it is not
# loaded on the hypervisor we fall back to `pfifo limit 0`, which is built into
# the kernel (no module) and also drops 100% of egress. Same lesson, same tool.
# =============================================================================
apply_fault_3() {
    if [ "$LAB_IF" = "$MGMT_IF" ]; then
        fail "fault 3: refusing to attach a qdisc to the management interface"
        return 1
    fi

    local kind=""
    tc qdisc del dev "$LAB_IF" root >/dev/null 2>&1     # idempotent reset

    if tc qdisc replace dev "$LAB_IF" root netem loss 100% >/dev/null 2>&1; then
        kind="netem"
    else
        modprobe sch_netem >/dev/null 2>&1
        if tc qdisc replace dev "$LAB_IF" root netem loss 100% >/dev/null 2>&1; then
            kind="netem"
        elif tc qdisc replace dev "$LAB_IF" root pfifo limit 0 >/dev/null 2>&1; then
            kind="pfifo"
            log "NOTE: sch_netem unavailable in this container; used the built-in fallback."
            log "NOTE: to get the richer variant, run on the Proxmox HOST:"
            log "NOTE:   modprobe sch_netem && echo sch_netem > /etc/modules-load.d/lab-fae.conf"
        else
            fail "fault 3: could not attach any drop-all qdisc to ${LAB_IF}"
            return 1
        fi
    fi

    # Postcondition 1: the qdisc is really attached, and is the one we chose.
    local out
    out="$(tc qdisc show dev "$LAB_IF" 2>/dev/null)"
    case "$kind:$out" in
        netem:*loss*)  : ;;
        pfifo:*pfifo*) : ;;
        *) fail "fault 3 did NOT take - qdisc on ${LAB_IF} is: ${out}"; return 1 ;;
    esac

    # Postcondition 2: FUNCTIONAL. A drop-all qdisc means a ping out eth1 must
    # fail. If it succeeds, the qdisc is attached but not doing its job and the
    # lab would be silently unarmed.
    if ping -c1 -W1 -I "$LAB_IF" "$PEER_B" >/dev/null 2>&1; then
        fail "fault 3: qdisc attached but ${PEER_B} is still reachable out ${LAB_IF}"
        return 1
    fi

    log "fault 3 applied"
    return 0
}

# --- Dispatch ----------------------------------------------------------------
case "$ROLE" in
  b)
    apply_fault_1
    apply_fault_2
    ;;
  a)
    apply_fault_3
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

# Syntax-check the generated script before enabling a unit that runs it at boot.
if ! bash -n "$FAULT_SCRIPT"; then
    echo "ERROR: generated ${FAULT_SCRIPT} failed syntax check - not enabling unit" >&2
    exit 4
fi

# =============================================================================
# 4. systemd oneshot so the faults survive a reboot.
#
# ORDERING MATTERS. `network-online.target` alone does NOT order us after
# ifupdown: without an enabled *-wait-online unit it is reached almost
# immediately. Running before networking.service means ifupdown reconfigures
# eth1 underneath us and can silently repair a fault - exactly what the ticket
# promises will not happen. Order against networking.service explicitly, and the
# generated script additionally waits for eth1 to carry a lab address.
#
# RemainAfterExit keeps the unit "active" once applied, which also gives the
# instructor a one-glance answer to "is this lab armed?".
# =============================================================================
echo "[*] Installing ${FAULT_UNIT} ..."
cat > "$UNIT_PATH" << EOF
[Unit]
Description=lab1-broken-router fault injection v2 (eth1 / 10.10.10.0/24 only)
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

systemctl daemon-reload >/dev/null 2>&1
if ! systemctl enable "$FAULT_UNIT" >/dev/null 2>&1; then
    echo "    WARNING: could not enable ${FAULT_UNIT} - faults will NOT survive a reboot"
fi

# =============================================================================
# 5. Apply the faults now, via the exact same code path that runs at boot.
# =============================================================================
echo "[*] Injecting faults ..."
if bash "$FAULT_SCRIPT" "$ROLE"; then
    INJECT_RC=0
else
    INJECT_RC=$?
    echo "    WARNING: fault script exited ${INJECT_RC}"
fi

# =============================================================================
# 6. MGMT GUARD - final, mandatory.
# Runs before the exit-code decision below, so the lifeline is asserted no
# matter how the injection went.
# =============================================================================
echo ""
mgmt_guard "post-break final"

# =============================================================================
# 7. Report. Indices only - no spoilers on stdout, the learner may be watching.
# =============================================================================
echo ""
if [ "$INJECT_RC" -eq 0 ]; then
    echo "=============================================================="
    echo " Role '${ROLE}' armed (fault set v2). Fault indices applied: ${FAULTS_APPLIED}"
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
