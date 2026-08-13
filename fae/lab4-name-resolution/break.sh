#!/bin/bash
# =============================================================================
# lab4-name-resolution :: break.sh
# -----------------------------------------------------------------------------
# Injects THREE layered name-resolution faults, then proves the management
# lifeline is still intact.
#
# Runs INSIDE a Debian 12 privileged LXC container as root, e.g.:
#     pct push 206 break.sh /root/break.sh && pct exec 206 -- bash /root/break.sh a
#     pct push 207 break.sh /root/break.sh && pct exec 207 -- bash /root/break.sh b
#
# Usage: break.sh <role>       role = a (server/CT206) | b (client/CT207)
#
# -----------------------------------------------------------------------------
# FAULT DISTRIBUTION
#   role a (server) -> faults 1 and 3
#   role b (client) -> fault 2
#
# WHY THIS SPLIT: each fault is found with a DIFFERENT tool, and fixing one
# REVEALS the next. A single fault teaches one command; a layered stack trains
# out the instinct to stop at the first thing you find - which is the actual
# difference between a junior and a senior on a live call.
#
#   FAULT 1 (server) - the resolver stops serving the lab segment.
#       Mechanism: 10-lab-plant.conf is rewritten so dnsmasq binds
#       127.0.0.1 ONLY (listen-address=127.0.0.1 + bind-interfaces), plus a
#       scoped INPUT DROP for udp/53 and tcp/53 arriving on eth1.
#
#       WHY THE DROP RULE IS PART OF FAULT 1, not a fourth fault: with nothing
#       listening on 10.40.40.10:53 the kernel answers a client's query with
#       ICMP port-unreachable, and dig reports "connection refused". That is a
#       DIFFERENT diagnosis from what this lab is teaching. The whole point of
#       fault 1 is the TIMEOUT signature - "nothing answered at all" - versus
#       REFUSED, which means something DID answer and said no. The DROP rule is
#       what produces a genuine timeout, and it is exactly how this looks in the
#       field when a service is moved to localhost behind a host firewall.
#       Both artifacts must be removed to clear the fault.
#
#       Discovery tools: `ss -ulnp` / `ss -tlnp` on the SERVER (dnsmasq is bound
#       to 127.0.0.1:53, not 10.40.40.10:53), `iptables -L INPUT -n -v` (the
#       drop counters climb while the client queries), and on the CLIENT
#       `dig @10.40.40.10 ...` reporting
#           ;; connection timed out; no servers could be reached
#
#       Note the DHCP side effect, which is realistic and intentional: the
#       faulted config carries no dhcp-range, so the segment's DHCP service is
#       down too. The client keeps working because its lease is 24h and because
#       lab4-net.sh has a documented static fallback. The ticket's line about
#       confirming the client is still addressed automatically points here.
#
#   FAULT 2 (client) - a stale /etc/hosts entry overrides DNS.
#       Mechanism: a WRONG record for hmi.plant.northstar.example pointing at
#       10.40.40.199, an address nothing answers on.
#
#       This is the classic "dig says it's fine but the app disagrees" trap.
#       /etc/nsswitch.conf lists `files` before `dns`, so ping, getent, curl,
#       and the application all take the lie from /etc/hosts, while dig - which
#       speaks to a nameserver directly and IGNORES both /etc/hosts and
#       nsswitch - returns the CORRECT answer. Every instinct says "DNS is
#       fine, must be the network". It is neither.
#
#       Discovery tool: `getent hosts hmi.plant.northstar.example` compared with
#       `dig +short hmi.plant.northstar.example` - they DISAGREE. Then
#       /etc/nsswitch.conf explains why, and /etc/hosts holds the lie.
#
#   FAULT 3 (server) - wrong A record served, plus aggressive TTL policy.
#       Mechanism: 20-plant-records.conf serves controller-a as 10.40.40.77
#       (nothing there), and a SEPARATE file 90-plant-cache.conf sets
#       local-ttl / neg-ttl to 3600 with a large cache.
#
#       Two lessons. First: a name that resolves is not a name that resolves
#       CORRECTLY - NOERROR with the wrong RDATA looks like success to every
#       tool that only checks the exit code. Second, and this is the one that
#       burns people: fixing the zone file is not enough. dnsmasq re-reads
#       /etc/hosts and its lease file on SIGHUP but NOT its own config, so
#       `systemctl reload dnsmasq` appears to do nothing and the learner
#       concludes their fix was wrong. It needs a restart - and the inflated
#       TTL means anything downstream that caches keeps serving the stale
#       answer until it expires. The 90- file is named to sort AFTER the record
#       file on purpose: fix the obvious file and the TTL policy is still there.
#
#       Discovery tool: `dig controller-a.plant.northstar.example` - the ANSWER
#       section shows the wrong address AND an absurd TTL counting down.
#
# -----------------------------------------------------------------------------
# *** SACRED INVARIANT ***
#   eth0, its address, and the default route via 192.168.10.1 are the learner's
#   SSH lifeline over Tailscale. NOTHING here may modify them.
#     - No bare `ip route add default` / `ip route del default` exists in this
#       file or in the persistence script it generates.
#     - The only firewall rules touched are scoped `-i eth1`, and are therefore
#       structurally incapable of affecting the management interface.
#     - The only dnsmasq bindings written are 127.0.0.1. Nothing can start
#       answering DHCP on the real house LAN.
#     - The script ends with a MGMT GUARD that hard-fails if either the eth0
#       address or the single default route is not exactly as expected. The
#       generated persistence script carries the same guard, so the invariant
#       is enforced on every unattended boot too.
#
# set -e is deliberately NOT used - a single failed injection must not leave the
# container half-configured with the guard never reached.
# =============================================================================
set -uo pipefail

# --- Role parsing ------------------------------------------------------------
ROLE="${1:-}"
case "$ROLE" in
    a)
        MGMT_IP="192.168.10.206"
        HOSTNAME_EXPECTED="lab-dns-a"
        FAULTS_APPLIED="1, 3"
        ;;
    b)
        MGMT_IP="192.168.10.207"
        HOSTNAME_EXPECTED="lab-dns-b"
        FAULTS_APPLIED="2"
        ;;
    *)
        echo "ERROR: role required. Usage: $0 <a|b>   (a = server/CT206, b = client/CT207)" >&2
        exit 2
        ;;
esac

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"
ZONE="plant.northstar.example"
DNS_SERVER="10.40.40.10"
FALLBACK_DNS="8.8.8.8"

CONF_SERVICE="/etc/dnsmasq.d/10-lab-plant.conf"
CONF_RECORDS="/etc/dnsmasq.d/20-plant-records.conf"
CONF_CACHE="/etc/dnsmasq.d/90-plant-cache.conf"

BASE_UNIT="lab4-net.service"
FAULT_SCRIPT="/usr/local/sbin/lab4-faults.sh"
FAULT_UNIT="lab4-faults.service"
FAULT_UNIT_PATH="/etc/systemd/system/${FAULT_UNIT}"

# Fault constants. Named here so break.sh and the generated persistence script
# cannot drift apart.
BAD_CONTROLLER_IP="10.40.40.77"    # fault 3: nothing lives here
BAD_HMI_IP="10.40.40.199"          # fault 2: nothing lives here either
BAD_TTL=3600                       # fault 3: absurd for a plant zone
HOSTS_FAULT_TAG="LAB4-FAULT"

# =============================================================================
# MGMT GUARD - the single most important function in this repo.
#
# Asserts eth0 still holds the expected address AND that there is EXACTLY ONE
# default route, via 192.168.10.1 out of eth0.
#
# Deliberately NOT built as `ip ... | grep -q ...`: under `set -o pipefail` the
# pipeline's status depends on both commands, which can invert the test in ways
# that are invisible on inspection. Capture, then compare strings.
#
# READ-ONLY by design. A guard that repairs state can hide the bug it exists to
# catch, and a guard that cannot fail is worse than no guard at all.
# =============================================================================
mgmt_guard() {
    local ctx="${1:-final check}"
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

echo "=============================================================="
echo " lab4-name-resolution break :: role=${ROLE}"
echo "=============================================================="

# --- Identity assertion: fail closed. Arming the wrong container is worse than
#     not arming at all, and role a's fault rewrites a DHCP server's config.
CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_EXPECTED" ]; then
    echo "ERROR: hostname is '${CURRENT_HOSTNAME}' but role '${ROLE}' expects '${HOSTNAME_EXPECTED}'." >&2
    echo "       Refusing to inject faults into the wrong container." >&2
    exit 2
fi

# Pre-flight: refuse to touch anything if the lifeline is already wrong.
mgmt_guard "pre-flight"

# The baseline must exist before it can be broken. Without it, break.sh would be
# writing faults on top of an unknown state and the lab would not be reproducible.
if [ ! -x /usr/local/sbin/lab4-net.sh ]; then
    echo "ERROR: baseline not installed (/usr/local/sbin/lab4-net.sh missing)." >&2
    echo "       Run: bash /root/setup.sh ${ROLE}" >&2
    exit 3
fi
if ! ip link show "$LAB_IF" >/dev/null 2>&1; then
    echo "ERROR: ${LAB_IF} not present - check the CT's net1 device is on vmbr3." >&2
    exit 3
fi
if [ "$ROLE" = "a" ]; then
    for f in "$CONF_SERVICE" "$CONF_RECORDS"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: ${f} missing - run setup.sh a first." >&2
            exit 3
        fi
    done
fi

# =============================================================================
# Generate the persistence script.
#
# The SAME script applies the faults now and re-applies them at boot, so there
# is exactly ONE definition of each fault and no possibility of the live state
# and the boot state disagreeing. A reboot must not accidentally repair the lab
# - the reporter in the ticket already tried rebooting, and the ticket promises
# it did not help.
#
# The generated script carries its own copy of the MGMT GUARD so the invariant
# is enforced on every unattended boot, not only when a human runs break.sh.
# =============================================================================
echo "[*] Writing persistence script ${FAULT_SCRIPT} ..."
mkdir -p "$(dirname "$FAULT_SCRIPT")"

{
    echo '#!/bin/bash'
    echo '# GENERATED BY break.sh - lab4-name-resolution fault persistence.'
    echo '# Re-applies the lab faults at boot.'
    echo '# Scoped to: the lab dnsmasq config files, INPUT rules that name -i eth1,'
    echo '# and one tagged line in /etc/hosts. Never touches eth0, its address, or'
    echo '# the default route.'
    echo "ROLE_DEFAULT=\"${ROLE}\""
    echo "MGMT_IP=\"${MGMT_IP}\""
    echo "ZONE=\"${ZONE}\""
    echo "DNS_SERVER=\"${DNS_SERVER}\""
    echo "FALLBACK_DNS=\"${FALLBACK_DNS}\""
    echo "CONF_SERVICE=\"${CONF_SERVICE}\""
    echo "CONF_RECORDS=\"${CONF_RECORDS}\""
    echo "CONF_CACHE=\"${CONF_CACHE}\""
    echo "BAD_CONTROLLER_IP=\"${BAD_CONTROLLER_IP}\""
    echo "BAD_HMI_IP=\"${BAD_HMI_IP}\""
    echo "BAD_TTL=\"${BAD_TTL}\""
    echo "HOSTS_FAULT_TAG=\"${HOSTS_FAULT_TAG}\""
    cat << 'LAB4_FAULTS_BODY'
set -uo pipefail

# The role is baked in at generation time, but an explicit argument wins so the
# script behaves as its own command line advertises (systemd passes it too).
ROLE="${1:-$ROLE_DEFAULT}"

MGMT_IF="eth0"
MGMT_GW="192.168.10.1"
LAB_IF="eth1"

RC=0
log()  { echo "lab4-faults[$ROLE]: $*"; }
fail() { log "ERROR: $*"; RC=1; }

# --- MGMT GUARD (identical contract to break.sh's) ---------------------------
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

mgmt_guard "pre-inject"

case "$ROLE" in

  # ===========================================================================
  # SERVER ROLE - faults 1 and 3
  # ===========================================================================
  a)
    # -----------------------------------------------------------------------
    # Boot-ordering safety. In LXC eth1 EXISTS from container start, so waiting
    # for the link to appear buys nothing. Wait for it to actually carry a lab
    # ADDRESS, which only happens once lab4-net.service has finished with it.
    # Without this we could restart dnsmasq before the address exists and it
    # would die on "unknown interface" - a lab bug that looks like fault 1 but
    # leaves a failed unit, which is a different and confusing symptom.
    # -----------------------------------------------------------------------
    LAB_READY=0
    for i in $(seq 1 30); do
        CUR="$(ip -4 addr show dev "$LAB_IF" 2>/dev/null)"
        case "$CUR" in *"inet 10.40.40."*) LAB_READY=1; break ;; esac
        sleep 1
    done
    [ "$LAB_READY" -eq 1 ] || log "WARNING: $LAB_IF has no 10.40.40.x address after 30s; continuing"

    # -----------------------------------------------------------------------
    # FAULT 3 (written first, applied by the same restart as fault 1)
    #
    # 3a. Wrong A record for controller-a. Deterministic: this file is the ONLY
    #     place any host-record for the zone is declared, so there is never a
    #     "which declaration wins" race. Every other record stays correct on
    #     purpose - a zone where everything is broken is a much easier puzzle
    #     than one where a single record lies.
    # -----------------------------------------------------------------------
    cat > "$CONF_RECORDS" << FAULT3_RECORDS
# =============================================================================
# lab4-name-resolution :: ${ZONE} zone records
# =============================================================================
host-record=controller-a.${ZONE},${BAD_CONTROLLER_IP}
host-record=hmi.${ZONE},10.40.40.50
host-record=historian.${ZONE},10.40.40.60
host-record=packer-01.${ZONE},10.40.40.70
host-record=gateway.${ZONE},10.40.40.1
FAULT3_RECORDS
    chmod 644 "$CONF_RECORDS"

    # -----------------------------------------------------------------------
    # 3b. TTL policy, in a file that sorts AFTER the record file.
    #     This is the "non-obvious file": a learner who fixes the obvious record
    #     file and restarts gets the right address back, but every answer still
    #     carries a one-hour TTL, so anything downstream that caches keeps the
    #     stale answer. Fixing the zone is not the same as invalidating the
    #     cache.
    # -----------------------------------------------------------------------
    cat > "$CONF_CACHE" << FAULT3_CACHE
# Plant zone caching policy.
local-ttl=${BAD_TTL}
neg-ttl=${BAD_TTL}
cache-size=10000
FAULT3_CACHE
    chmod 644 "$CONF_CACHE"
    log "fault 3 files written"

    # -----------------------------------------------------------------------
    # FAULT 1 - service binding moved to loopback only.
    #
    # Note what is NOT in this file: no `interface=`, no `dhcp-range`. Both are
    # deliberate.
    #   - `interface=eth1` had to go, or dnsmasq would keep binding the lab
    #     address and the fault would silently not apply. This is why fault 1
    #     rewrites the whole file instead of dropping an override alongside it:
    #     an override cannot UNSET a directive, and two files both declaring a
    #     binding would make the outcome depend on merge order. Deterministic
    #     beats elegant.
    #   - dropping `dhcp-range` avoids dnsmasq complaining that the range has no
    #     matching interface. The DHCP service going down with DNS is realistic
    #     and is covered by the client's 24h lease plus its static fallback.
    # -----------------------------------------------------------------------
    cat > "$CONF_SERVICE" << FAULT1_SERVICE
# =============================================================================
# lab4-name-resolution :: dnsmasq service binding
# =============================================================================
listen-address=127.0.0.1
bind-interfaces
no-dhcp-interface=${MGMT_IF}
no-dhcp-interface=${LAB_IF}
no-dhcp-interface=lo

no-resolv
server=${FALLBACK_DNS}

domain=${ZONE}
local=/${ZONE}/
domain-needed
bogus-priv

log-queries
FAULT1_SERVICE
    chmod 644 "$CONF_SERVICE"

    # Validate the merged config before restarting. A dnsmasq that fails to
    # start at all is a DIFFERENT symptom from one that answers only on
    # loopback, and it would teach the wrong lesson.
    if ! dnsmasq --test >/dev/null 2>&1; then
        fail "dnsmasq --test failed on the faulted config; leaving service as-is"
        dnsmasq --test 2>&1 | sed 's/^/         /'
    else
        if systemctl restart dnsmasq >/dev/null 2>&1; then
            log "dnsmasq restarted with faulted config"
        else
            fail "dnsmasq failed to restart with the faulted config"
        fi
    fi
    sleep 1

    # -----------------------------------------------------------------------
    # FAULT 1 (second artifact) - drop DNS arriving on the lab interface.
    #
    # SCOPED BY `-i eth1`. This rule is structurally incapable of matching
    # traffic on the management interface: eth0 is never named, and an INPUT
    # rule matching on input device cannot fire for packets that arrived on a
    # different device. SSH (tcp/22 on eth0) is untouched.
    #
    # -C ... || -A makes it idempotent, so the boot path never stacks duplicates.
    # -----------------------------------------------------------------------
    if command -v iptables >/dev/null 2>&1; then
        for proto in udp tcp; do
            if iptables -C INPUT -i "$LAB_IF" -p "$proto" --dport 53 -j DROP 2>/dev/null; then
                log "drop rule already present (${proto}/53 on ${LAB_IF})"
            elif iptables -A INPUT -i "$LAB_IF" -p "$proto" --dport 53 -j DROP 2>/dev/null; then
                log "installed drop rule (${proto}/53 on ${LAB_IF})"
            else
                fail "could not install ${proto}/53 drop rule on ${LAB_IF}"
            fi
        done
    else
        log "WARNING: iptables unavailable - fault 1 will present as REFUSED, not TIMEOUT"
    fi

    # -----------------------------------------------------------------------
    # POSTCONDITIONS. Never claim success from the fact that a write returned 0.
    # -----------------------------------------------------------------------
    SOCKETS="$( { ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null; } || true )"

    # (i) SAFETY FIRST: even a faulted config must not expose DNS/DHCP on the
    #     management address or a wildcard. If it does, tear the service down.
    VIOLATION=""
    case "$SOCKETS" in *"${MGMT_IP}:53"*) VIOLATION="${VIOLATION} ${MGMT_IP}:53" ;; esac
    case "$SOCKETS" in *"${MGMT_IP}:67"*) VIOLATION="${VIOLATION} ${MGMT_IP}:67" ;; esac
    case "$SOCKETS" in *"0.0.0.0:53"*)    VIOLATION="${VIOLATION} 0.0.0.0:53" ;; esac
    case "$SOCKETS" in *"[::]:53"*)       VIOLATION="${VIOLATION} [::]:53" ;; esac
    if [ -n "$VIOLATION" ]; then
        log "SAFETY VIOLATION - dnsmasq exposed on:${VIOLATION} - stopping it"
        systemctl stop dnsmasq >/dev/null 2>&1
        fail "dnsmasq was exposed outside the lab segment; service stopped"
    fi

    # (ii) fault 1 took: bound to loopback, NOT to the lab address.
    F1_LOOPBACK=0
    F1_LABBOUND=1
    case "$SOCKETS" in *"127.0.0.1:53"*) F1_LOOPBACK=1 ;; esac
    case "$SOCKETS" in *"${DNS_SERVER}:53"*) F1_LABBOUND=1 ;; *) F1_LABBOUND=0 ;; esac
    if [ "$F1_LOOPBACK" -eq 1 ] && [ "$F1_LABBOUND" -eq 0 ]; then
        log "fault 1 applied"
    else
        fail "fault 1 did NOT take (loopback bound=${F1_LOOPBACK}, lab bound=${F1_LABBOUND})"
        printf '%s\n' "$SOCKETS" | sed 's/^/         /'
    fi

    # (iii) fault 3 took: ask the server itself, on loopback, where it still
    #       answers. A wrong answer here is the postcondition.
    if command -v dig >/dev/null 2>&1; then
        F3_ANSWER="$(dig +short +time=3 +tries=1 @127.0.0.1 "controller-a.${ZONE}" A 2>/dev/null | head -n1)"
        if [ "$F3_ANSWER" = "$BAD_CONTROLLER_IP" ]; then
            log "fault 3 applied"
        else
            fail "fault 3 did NOT take - loopback answer was '${F3_ANSWER:-<none>}', expected ${BAD_CONTROLLER_IP}"
        fi
    else
        log "WARNING: dig unavailable; fault 3 verified by file contents only"
        grep -q "controller-a.${ZONE},${BAD_CONTROLLER_IP}" "$CONF_RECORDS" 2>/dev/null \
            || fail "fault 3 record not present in ${CONF_RECORDS}"
    fi
    [ -s "$CONF_CACHE" ] || fail "fault 3 TTL file ${CONF_CACHE} missing"
    ;;

  # ===========================================================================
  # CLIENT ROLE - fault 2
  # ===========================================================================
  b)
    # -----------------------------------------------------------------------
    # FAULT 2 - a stale /etc/hosts entry that beats DNS.
    #
    # WHY THIS NEEDS PERSISTENCE AT ALL: PVE regenerates /etc/hosts on every
    # container start to keep the hostname line correct. A fault written only
    # once would be wiped by the first reboot - which is exactly the reboot the
    # ticket tells the learner to perform.
    #
    # The line is TAGGED. Every rewrite (here and in setup.sh's reset) selects
    # on the tag, never on the hostname, so a legitimate entry can never be
    # collateral damage.
    #
    # Written via a temp file + mv: a truncated /etc/hosts breaks sudo's own
    # hostname lookup and would turn a resolution lab into an unusable box.
    # -----------------------------------------------------------------------
    if [ ! -f /etc/hosts ]; then
        fail "/etc/hosts does not exist - refusing to create one from scratch"
    else
        HOSTS_TMP="$(mktemp /etc/hosts.lab4.XXXXXX)" || HOSTS_TMP=""
        if [ -z "$HOSTS_TMP" ]; then
            fail "could not create a temp file next to /etc/hosts"
        else
            # Strip any previous tagged line first, so re-running is idempotent
            # and never stacks duplicates.
            if grep -v "$HOSTS_FAULT_TAG" /etc/hosts > "$HOSTS_TMP" 2>/dev/null && [ -s "$HOSTS_TMP" ]; then
                printf '%s\thmi.%s\thmi\t# %s\n' "$BAD_HMI_IP" "$ZONE" "$HOSTS_FAULT_TAG" >> "$HOSTS_TMP"
                chmod 644 "$HOSTS_TMP"
                if mv -f "$HOSTS_TMP" /etc/hosts; then
                    log "fault 2 written to /etc/hosts"
                else
                    rm -f "$HOSTS_TMP"
                    fail "could not install the rewritten /etc/hosts"
                fi
            else
                rm -f "$HOSTS_TMP"
                fail "refusing to install an empty /etc/hosts"
            fi
        fi
    fi

    # POSTCONDITION: the NSS path must actually return the lie. Checking that
    # the line exists in the file is not enough - if nsswitch had been changed
    # to put dns first, the fault would be inert and the lab would silently
    # have only two faults.
    F2_GETENT="$(getent hosts "hmi.${ZONE}" 2>/dev/null | awk '{print $1}' | head -n1)"
    if [ "$F2_GETENT" = "$BAD_HMI_IP" ]; then
        log "fault 2 applied"
    else
        fail "fault 2 did NOT take - getent returned '${F2_GETENT:-<none>}', expected ${BAD_HMI_IP}"
        grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf 2>/dev/null | sed 's/^/         /'
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
LAB4_FAULTS_BODY
} > "$FAULT_SCRIPT"

chmod 700 "$FAULT_SCRIPT"

# Syntax-check the generated script BEFORE enabling any unit that runs it.
# A unit pointing at a script with a syntax error fails on every boot and looks
# like a fourth, undocumented fault.
if ! bash -n "$FAULT_SCRIPT"; then
    echo "ERROR: generated ${FAULT_SCRIPT} failed syntax check - not enabling unit" >&2
    exit 4
fi

# =============================================================================
# systemd oneshot so the faults survive a reboot.
#
# ORDERING MATTERS, TWICE:
#   1. `network-online.target` ALONE does not order us after ifupdown - without
#      an enabled *-wait-online unit that target is reached almost immediately.
#      We would race ifupdown, and on a bad race a reboot would silently REPAIR
#      the lab. Order explicitly against networking.service.
#   2. We must also run after lab4-net.service, the baseline helper. That unit
#      sets eth1's address and restarts dnsmasq with whatever config is on disk.
#      If we ran first, its restart would come second and everything would still
#      work out - but the fault verification inside this script would run before
#      the address existed and would report a false failure.
#
# RemainAfterExit keeps the unit "active" once applied, which is a cheap way for
# the instructor to see at a glance whether the lab is armed:
#     systemctl is-active lab4-faults.service
# =============================================================================
echo "[*] Installing ${FAULT_UNIT} ..."
cat > "$FAULT_UNIT_PATH" << EOF
[Unit]
Description=lab4-name-resolution fault injection (lab segment only)
After=network-online.target networking.service ${BASE_UNIT}
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
chmod 644 "$FAULT_UNIT_PATH"

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "$FAULT_UNIT" >/dev/null 2>&1 || echo "    WARNING: could not enable ${FAULT_UNIT}"

# Confirm persistence is really armed. `systemctl is-enabled` exits NON-ZERO for
# a disabled unit BY DESIGN - piping it into grep under pipefail inverts the
# test. Capture the value, then compare it.
FAULT_ENABLED="$(systemctl is-enabled "$FAULT_UNIT" 2>/dev/null || true)"
if [ "$FAULT_ENABLED" = "enabled" ]; then
    echo "    ${FAULT_UNIT} is enabled (faults survive reboot)"
    PERSIST_OK=0
else
    echo "    WARNING: ${FAULT_UNIT} is '${FAULT_ENABLED:-unknown}', expected 'enabled'"
    PERSIST_OK=1
fi

# =============================================================================
# Apply the faults NOW, through the exact same code path that runs at boot.
# One definition of each fault; no drift between "armed" and "armed after
# reboot".
# =============================================================================
echo "[*] Injecting faults ..."
if bash "$FAULT_SCRIPT" "$ROLE"; then
    INJECT_RC=0
else
    INJECT_RC=$?
    echo "    WARNING: fault script exited ${INJECT_RC}"
fi

# =============================================================================
# MGMT GUARD - final, mandatory. Runs BEFORE the exit-code decision so the
# lifeline is always asserted no matter how the injection went.
# =============================================================================
echo ""
mgmt_guard "post-break final"

# =============================================================================
# Report. INDICES ONLY - no spoilers on stdout. The learner may be watching the
# deploy, and the diagnosis is the exercise.
# =============================================================================
echo ""
if [ "$INJECT_RC" -eq 0 ] && [ "$PERSIST_OK" -eq 0 ]; then
    echo "=============================================================="
    echo " Role '${ROLE}' armed. Fault indices applied: ${FAULTS_APPLIED}"
    echo " Persistence: ${FAULT_UNIT} (enabled, survives reboot)"
    echo " Reset to working state: bash /root/setup.sh ${ROLE}"
    echo "=============================================================="
    exit 0
else
    echo "=============================================================="
    echo " Role '${ROLE}' NOT correctly armed (injector exit ${INJECT_RC},"
    echo " persistence status ${PERSIST_OK})."
    echo " Intended fault indices: ${FAULTS_APPLIED}"
    echo " Management lifeline is intact, but the lab state is unreliable."
    echo " Reset and retry: bash /root/setup.sh ${ROLE} && bash /root/break.sh ${ROLE}"
    echo "=============================================================="
    exit 1
fi
