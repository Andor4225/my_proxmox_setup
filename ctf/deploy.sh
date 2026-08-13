#!/bin/bash
#
# CTF Lab Master Deployer
# Creates LXC containers on Proxmox and provisions each CTF challenge.
#
# Usage: Run this on the PROXMOX HOST (or via SSH from your workstation)
#   ssh root@proxmox bash /root/ctf/deploy.sh deploy all
#
# Container assignments (re-mapped 2026-07-28 — see "CTID re-map" below):
#   CTID 211 - ctf-web-exploit      192.168.10.211  (Web Exploitation)
#   CTID 212 - ctf-linux-privesc    192.168.10.212  (Linux Privilege Escalation)
#   CTID 213 - ctf-crypto-forensics 192.168.10.213  (Crypto & Forensics)
#   CTID 214 - ctf-network-recon    192.168.10.214  (Network Recon & Services)
#   CTID 215 - ctf-scoreboard       192.168.10.215  (CTF Scoreboard)
#
# CTID re-map: this lab originally lived on 201-205. Those CTIDs and IPs are now
# held by the FAE practice labs (CT 201-207), which are deliberately broken and
# actively in use. The CTF moved to 211-215 so both labs coexist. Addressing is
# now STATIC (it was DHCP, which contradicted the documented IPs and made the
# Kali firewall whitelist unreliable).
#
# NOTE: the UniFi VLAN70->VLAN10 whitelist for the Kali machine covers
# 192.168.10.201-205. It must be widened to .211-.215 for Kali to reach this lab.
#
# INVOCATION: run this as a FILE (`bash /root/ctf/deploy.sh`), never piped as
# `bash -s < deploy.sh`. Piping sets $0 to "bash", so SCRIPT_DIR resolves to the
# remote CWD and every challenge setup script fails to resolve.

set -euo pipefail

# ── Configuration ──
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"
BRIDGE="vmbr0"
GATEWAY="192.168.10.1"
CIDR="24"
# Two resolvers: a single one is a silent single point of failure during apt.
# Do NOT drop this and let pct inherit the host's resolv.conf — the host runs
# Tailscale MagicDNS (100.100.100.100), which containers cannot reach, and apt
# then hangs forever at 0% CPU with no error.
NAMESERVER="8.8.8.8 1.1.1.1"
MEMORY=1024        # MB per container
SWAP=512
DISK=8             # GB per container
CORES=2
PASSWORD="ctfadmin123"  # Root password for containers

# These containers are DELIBERATELY VULNERABLE and are reachable from the Kali
# VLAN. They run UNPRIVILEGED with no nesting: solving a privesc challenge is
# supposed to yield root in the container, not root on the PVE host. A
# privileged LXC would make that escalation a hypervisor compromise, and this
# same host runs CT 300 (dfwagentops.com, production) plus the backup shares.
# No challenge setup script uses docker/mount/modprobe, so nothing needs it.
UNPRIVILEGED=1
FEATURES=""

# CTIDs this script must NEVER touch, whatever it is asked to do:
#   100=ubuntu-target  201-207=FAE practice labs  300=web-server (dfwagentops.com)
#   900/901=OpenClaw VM templates
PROTECTED_IDS=(100 201 202 203 204 205 206 207 300 900 901)

# Container definitions: CTID|NAME|IP|SETUP_SCRIPT
declare -A CONTAINERS=(
    [web]="211|ctf-web-exploit|192.168.10.211|challenges/web-exploit/setup.sh"
    [privesc]="212|ctf-linux-privesc|192.168.10.212|challenges/linux-privesc/setup.sh"
    [forensics]="213|ctf-crypto-forensics|192.168.10.213|challenges/crypto-forensics/setup.sh"
    [network]="214|ctf-network-recon|192.168.10.214|challenges/network-recon/setup.sh"
    [scoreboard]="215|ctf-scoreboard|192.168.10.215|scoreboard/setup.sh"
)

# Deployment order. Keep this as the single source of iteration order so a new
# challenge only has to be added in two places (CONTAINERS + here).
ORDER=(web privesc forensics network scoreboard)

# The set of CTIDs this script may touch, derived from CONTAINERS so the guard
# can never drift out of sync with the actual definitions.
CTF_ALLOWED_IDS=()
for _key in "${ORDER[@]}"; do
    CTF_ALLOWED_IDS+=("${CONTAINERS[$_key]%%|*}")
done
unset _key

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# err/warn go to stderr so `... 2>/dev/null` and journald can separate them.
log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${BLUE}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()  { echo -e "${RED}[-]${NC} $1" >&2; }

# ── Safety ──

# Hard stop before any destructive pct call. Every create/stop/destroy path
# routes through this. A typo'd CTID here would take out a live service or a
# lab container mid-exercise.
assert_safe_ctid() {
    local ctid="${1-}"

    # Positive whitelist, matched as an exact STRING.
    #
    # This deliberately avoids an integer range test. `[ "$ctid" -lt 211 ]`
    # returns exit status 2 ("integer expression expected") on an empty or
    # non-numeric value, and because that test sits in an `if` condition it is
    # exempt from `set -e` — so the condition evaluated false, the guard
    # returned success, and the bad value was waved straight through to
    # `pct destroy`. The triggering values are exactly the ones a field-order
    # mistake in CONTAINERS produces: a container name, or a setup-script path.
    # Reproduced failing open before this was changed.
    local ok=0 allowed
    for allowed in "${CTF_ALLOWED_IDS[@]}"; do
        if [ "$ctid" = "$allowed" ]; then
            ok=1
            break
        fi
    done
    if [ "$ok" -ne 1 ]; then
        err "REFUSING to touch CTID '$ctid' — not a CTF container."
        err "Allowed: ${CTF_ALLOWED_IDS[*]}"
        exit 1
    fi

    # Belt and braces: an explicit deny list, in case the whitelist is ever
    # widened carelessly.
    local p
    for p in "${PROTECTED_IDS[@]}"; do
        if [ "$ctid" = "$p" ]; then
            err "REFUSING to touch CTID $ctid — it is on the protected list."
            err "Protected: ${PROTECTED_IDS[*]}"
            exit 1
        fi
    done
}

# Confirm prompt that is safe under `ssh host bash deploy.sh ...` (no TTY).
# Without the TTY test, `read` gets EOF and $REPLY stays empty.
# Set CTF_ASSUME_YES=1 to pre-authorise destructive steps in automation.
confirm() {
    local prompt="$1"
    if [ "${CTF_ASSUME_YES:-0}" = "1" ]; then
        info "$prompt -> auto-yes (CTF_ASSUME_YES=1)"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "$prompt -> no TTY to ask on, assuming NO."
        warn "Re-run with CTF_ASSUME_YES=1 to proceed non-interactively."
        return 1
    fi
    read -p "    $prompt [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ── Functions ──
#
# create_container returns: 0 = deployed, 1 = failed, 3 = skipped by operator.
create_container() {
    local ctid="$1"
    local name="$2"
    local ip="$3"
    local setup_script="$4"

    assert_safe_ctid "$ctid"

    # Resolve the setup script BEFORE creating anything, so a missing script
    # does not leave a bare container behind.
    local script_path="${SCRIPT_DIR}/${setup_script}"
    if [ ! -f "$script_path" ]; then
        err "Setup script not found: $script_path"
        return 1
    fi

    if pct status "$ctid" &>/dev/null; then
        warn "Container $ctid ($name) already exists."
        if confirm "Destroy and recreate $ctid ($name)?"; then
            log "Stopping and destroying $ctid..."
            pct stop "$ctid" 2>/dev/null || true
            sleep 2
            # Do NOT swallow this failure: a locked or still-stopping CT makes
            # pct destroy fail, and the subsequent pct create then dies with
            # "already exists", which points at entirely the wrong problem.
            if ! pct destroy "$ctid" --purge; then
                err "Could not destroy $ctid (locked or still stopping) — skipping $name."
                return 1
            fi
        else
            warn "Skipping $name."
            return 3
        fi
    fi

    log "Creating container $ctid ($name) at ${ip}..."
    local -a create_args=(
        --hostname "$name"
        --rootfs "${STORAGE}:${DISK}"
        --memory "$MEMORY"
        --swap "$SWAP"
        --cores "$CORES"
        --net0 "name=eth0,bridge=${BRIDGE},ip=${ip}/${CIDR},gw=${GATEWAY}"
        --nameserver "$NAMESERVER"
        --password "$PASSWORD"
        --unprivileged "$UNPRIVILEGED"
        --start 0
    )
    [ -n "$FEATURES" ] && create_args+=(--features "$FEATURES")

    if ! pct create "$ctid" "$TEMPLATE" "${create_args[@]}"; then
        err "pct create failed for $ctid ($name)."
        return 1
    fi

    log "Starting container $ctid..."
    if ! pct start "$ctid"; then
        err "pct start failed for $ctid ($name)."
        return 1
    fi

    info "Waiting for container to initialize..."
    local retries=0
    while ! pct exec "$ctid" -- test -f /etc/hostname 2>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if [ "$retries" -gt 30 ]; then
            err "Container $ctid failed to start within 30 seconds."
            return 1
        fi
    done

    # Gate on DNS + reachability, which is what actually matters before apt.
    # `ping` would also test an ICMP path the template may not even have a
    # binary for, and would burn the full timeout misleadingly if absent.
    info "Waiting for network + DNS..."
    retries=0
    while ! pct exec "$ctid" -- getent hosts deb.debian.org &>/dev/null; do
        sleep 2
        retries=$((retries + 1))
        if [ "$retries" -gt 15 ]; then
            warn "DNS not resolving in $name yet — proceeding, apt may fail."
            break
        fi
    done

    log "Copying setup script to container $ctid..."
    pct push "$ctid" "$script_path" /root/setup.sh --perms 755

    log "Running setup script in container $ctid (this may take a few minutes)..."
    # `if !` puts this in a condition context, so a non-zero setup.sh does not
    # abort the whole batch via set -e/pipefail. One bad challenge must not
    # silently prevent the remaining containers from ever being created.
    if ! pct exec "$ctid" -- bash /root/setup.sh 2>&1 | while IFS= read -r line; do
            echo "    [$name] $line"
        done; then
        warn "setup.sh in $name exited non-zero — container left in place, continuing."
    fi

    # Functional check: confirm the container actually came up on the static IP
    # we asked for, rather than trusting that pct create accepted the flag.
    # `|| true` is required — under pipefail a failing pct exec would otherwise
    # kill the entire run here and make the -z branch below unreachable.
    local actual_ip
    actual_ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$actual_ip" ]; then
        warn "Container $name is running but no IP could be determined."
    elif [ "$actual_ip" != "$ip" ]; then
        warn "Container $name expected ${ip} but came up on ${actual_ip}."
    else
        log "Container $name is ready at ${GREEN}${actual_ip}${NC}"
    fi

    return 0
}

destroy_container() {
    local ctid="$1"
    local name="$2"

    assert_safe_ctid "$ctid"

    if pct status "$ctid" &>/dev/null; then
        log "Stopping container $ctid ($name)..."
        pct stop "$ctid" 2>/dev/null || true
        sleep 2
        log "Destroying container $ctid ($name)..."
        pct destroy "$ctid" --purge
        log "Container $ctid ($name) destroyed."
    else
        info "Container $ctid ($name) does not exist."
    fi
}

deploy_target() {
    local key="$1"
    local def="${CONTAINERS[$key]}"
    local ctid name ip script
    IFS='|' read -r ctid name ip script <<< "$def"
    create_container "$ctid" "$name" "$ip" "$script"
}

destroy_target() {
    local key="$1"
    local def="${CONTAINERS[$key]}"
    local ctid name ip script
    IFS='|' read -r ctid name ip script <<< "$def"
    destroy_container "$ctid" "$name"
}

show_status() {
    local key def ctid name ip script status actual
    echo
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                          ${GREEN}CTF Lab Status${NC}                            ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════╣${NC}"

    for key in "${ORDER[@]}"; do
        def="${CONTAINERS[$key]}"
        IFS='|' read -r ctid name ip script <<< "$def"

        status="NOT CREATED"
        actual="-"
        if pct status "$ctid" &>/dev/null; then
            # || true: same set -e/pipefail class as the IP probe above; the CT
            # can vanish between the check and this line.
            status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || true)
            [ -n "$status" ] || status="unknown"
            if [ "$status" = "running" ]; then
                status="RUNNING"
                actual=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
                [ -n "$actual" ] || actual="?"
            fi
        fi

        # Plain %-s fields only. Embedding ANSI escapes inside a printf field
        # makes the escape bytes count toward the width and misaligns columns.
        printf "${BLUE}║${NC}  CTID %-4s %-24s %-12s %-15s ${BLUE}║${NC}\n" \
            "$ctid" "$name" "$status" "$actual"
    done

    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

usage() {
    echo "CTF Lab Deployer for Proxmox"
    echo
    echo "Usage: $0 <command> [target]"
    echo
    echo "Commands:"
    echo "  deploy [all|web|privesc|forensics|network|scoreboard]"
    echo "      Deploy one or all CTF challenge containers (default: all)"
    echo
    echo "  destroy <all|web|privesc|forensics|network|scoreboard>"
    echo "      Destroy CTF containers. Target is REQUIRED."
    echo
    echo "  reset <all|web|privesc|forensics|network|scoreboard>"
    echo "      Destroy and redeploy. Target is REQUIRED."
    echo
    echo "  status"
    echo "      Show status of all CTF containers"
    echo
    echo "Containers:"
    echo "  CTID 211 / 192.168.10.211 - Web Exploitation (SQLi, XSS, SSRF)"
    echo "  CTID 212 / 192.168.10.212 - Linux Privesc (SUID, cron, sudo, passwd)"
    echo "  CTID 213 / 192.168.10.213 - Crypto & Forensics (encoding, stego, log analysis)"
    echo "  CTID 214 / 192.168.10.214 - Network Recon (FTP, hidden services, port knocking)"
    echo "  CTID 215 / 192.168.10.215 - Scoreboard (flag submission & tracking)"
    echo
    echo "Environment:"
    echo "  CTF_ASSUME_YES=1   Pre-authorise destructive prompts (non-interactive runs)"
    echo
    echo "Exit codes: 0 = all OK, 1 = usage/guard error, 2 = one or more targets failed/skipped"
}

require_target() {
    local cmd="$1" target="$2"
    # Destructive verbs must never inherit a default of "all". With
    # CTF_ASSUME_YES=1 set in a cron or delegation, `deploy.sh destroy` with a
    # forgotten argument would wipe the lab with no prompt at all.
    if [ -z "$target" ]; then
        err "'$cmd' requires an explicit target (all|web|privesc|forensics|network|scoreboard)."
        exit 1
    fi
    if [ "$target" != "all" ] && [ -z "${CONTAINERS[$target]+x}" ]; then
        err "Unknown target: $target"
        exit 1
    fi
}

# ── Main ──

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

COMMAND="$1"
RAW_TARGET="${2-}"

failed=0

case "$COMMAND" in
    deploy)
        TARGET="${RAW_TARGET:-all}"
        if [ "$TARGET" != "all" ] && [ -z "${CONTAINERS[$TARGET]+x}" ]; then
            err "Unknown target: $TARGET"
            usage
            exit 1
        fi
        log "CTF Lab Deployer starting..."
        if [ "$TARGET" = "all" ]; then
            for key in "${ORDER[@]}"; do
                rc=0
                deploy_target "$key" || rc=$?
                case "$rc" in
                    0) ;;
                    3) warn "'$key' was skipped."; failed=$((failed + 1)) ;;
                    *) err "deploy of '$key' FAILED — continuing with the rest."
                       failed=$((failed + 1)) ;;
                esac
                echo
            done
        else
            rc=0
            deploy_target "$TARGET" || rc=$?
            [ "$rc" -eq 0 ] || failed=1
        fi
        show_status
        ;;
    destroy)
        require_target destroy "$RAW_TARGET"
        TARGET="$RAW_TARGET"
        if [ "$TARGET" = "all" ]; then
            warn "This will destroy ALL CTF containers (${CTF_ALLOWED_IDS[*]})!"
            if confirm "Are you sure?"; then
                for key in "${ORDER[@]}"; do
                    destroy_target "$key" || failed=$((failed + 1))
                done
            fi
        else
            if confirm "Destroy CTF container '$TARGET'?"; then
                destroy_target "$TARGET" || failed=1
            else
                warn "Aborted."
            fi
        fi
        show_status
        ;;
    reset)
        require_target reset "$RAW_TARGET"
        TARGET="$RAW_TARGET"
        if [ "$TARGET" = "all" ]; then
            warn "This will destroy and redeploy ALL CTF containers (${CTF_ALLOWED_IDS[*]})!"
            if confirm "Are you sure?"; then
                for key in "${ORDER[@]}"; do
                    destroy_target "$key" || failed=$((failed + 1))
                    rc=0
                    deploy_target "$key" || rc=$?
                    [ "$rc" -eq 0 ] || failed=$((failed + 1))
                    echo
                done
            fi
        else
            if confirm "Reset (destroy + redeploy) CTF container '$TARGET'?"; then
                destroy_target "$TARGET" || failed=1
                rc=0
                deploy_target "$TARGET" || rc=$?
                [ "$rc" -eq 0 ] || failed=1
            else
                warn "Aborted."
            fi
        fi
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        err "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac

if [ "$failed" -ne 0 ]; then
    err "$failed target(s) failed or were skipped."
    exit 2
fi
exit 0
