#!/bin/bash
# =============================================================================
# gen-syslog.sh — log generator for Lab 3, "The Raw Log Playground"
# =============================================================================
#
# PURPOSE
#   Produce a large, realistic, deliberately MESSY set of Linux log files that
#   a Field Application Engineer candidate will parse with a Python script they
#   write from scratch. Nothing here is "broken" — the logs ARE the exercise.
#
# WHAT IT WRITES
#   /var/log/syslog       >= 10,000 lines, chronologically ordered
#   /var/log/syslog.1.gz  ~4,500 older lines, same format, gzipped (rotation)
#   /var/log/auth.log     sshd auth noise + failure bursts TIME-CORRELATED
#                         with the NIC-flap episodes in syslog
#
# WHY IT IS BUILT THIS WAY
#   * awk, not bash loops. A naive `for i in $(seq 1 10000)` with subshells per
#     line takes minutes in an LXC container. A single awk pass takes ~1 second.
#     Generation speed matters because setup.sh runs this synchronously.
#   * Errors are injected in TIME-CLUSTERED BURSTS, never uniformly scattered.
#     This is the whole pedagogical point: a learner who only does
#     `grep -c error` gets a number; a learner who buckets by timestamp sees
#     episodes, and can then join those windows against auth.log. Uniform
#     random noise would make correlation impossible to discover.
#   * syslog is emitted in monotonic time order directly (no sort needed).
#     auth.log is emitted with an epoch key, sorted numerically, then the key is
#     stripped — because sorting "Jul  4 09:00:00" as TEXT is wrong (day field
#     is space-padded, months are not lexicographically ordered).
#   * Deterministic-ish: srand(SEED) means the same seed on the same awk
#     implementation reproduces the same logs. mawk (Debian default) and gawk
#     have different PRNGs, so output is stable per-machine, not across
#     machines. That is fine for a lab; override with GEN_SEED= if desired.
#
# NETWORK SAFETY
#   This script writes files under /var/log and NOTHING ELSE. It never touches
#   interfaces, addresses, routes, or any network configuration. The flapping
#   interface in the synthetic logs is deliberately named **eth1**, NOT eth0 —
#   eth0 is the learner's real SSH lifeline and must never be implicated by a
#   log line a nervous candidate might act on.
#
# IDEMPOTENT: re-running overwrites the three files cleanly.
# =============================================================================

# set -e is intentionally NOT used: we want the verification/summary block at
# the end to run and report even if one generation step had a hiccup.
set -uo pipefail

LOGDIR="${LOGDIR:-/var/log}"
HOSTNAME_TAG="${HOSTNAME_TAG:-lab-logs}"

# ---------------------------------------------------------------------------
# TARGET ASSERTION — do not remove.
# This script OVERWRITES $LOGDIR/{syslog,auth.log,syslog.1.gz}, and LOGDIR
# defaults to /var/log. This file also lives in the repo ON the Proxmox host,
# so a stray `bash labs/lab3-log-playground/gen-syslog.sh` from the wrong shell
# would truncate the hypervisor's real syslog and destroy /var/log/auth.log —
# the authentication record for a host running fail2ban and holding SSH keys
# for the Pi, OpenClaw, and the MCP server. That loss is irreversible.
# Guard is skipped when LOGDIR has been pointed somewhere harmless for testing.
# ---------------------------------------------------------------------------
if [ "$LOGDIR" = "/var/log" ]; then
    if [ -e /etc/pve/.version ]; then
        echo "[FAIL] This is the Proxmox HOST. gen-syslog.sh runs INSIDE CT 205 only." >&2
        echo "       pct exec 205 -- /usr/local/sbin/gen-syslog.sh" >&2
        exit 1
    fi
    if [ "${GEN_FORCE:-0}" != "1" ] && [ "$(hostname 2>/dev/null)" != "$HOSTNAME_TAG" ]; then
        echo "[FAIL] hostname is '$(hostname 2>/dev/null)', expected '$HOSTNAME_TAG' (CT 205)." >&2
        echo "       Refusing to overwrite ${LOGDIR}/{syslog,auth.log,syslog.1.gz}." >&2
        echo "       Override deliberately with GEN_FORCE=1, or set LOGDIR=/some/scratch." >&2
        exit 1
    fi
fi
SEED="${GEN_SEED:-20260704}"

SYSLOG_LINES="${SYSLOG_LINES:-11000}"   # >10k required; extra headroom
ROTATED_LINES="${ROTATED_LINES:-4500}"  # the older, gzipped generation

# Scratch space for the awk sources and the inter-pass correlation handoff.
WORK="$(mktemp -d /tmp/gen-syslog.XXXXXX)" || { echo "[FAIL] mktemp"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

NICFILE="$WORK/nic-windows.txt"   # "<start_epoch> <end_epoch> <attacker_ip>"
SPANFILE="$WORK/span.txt"         # total seconds covered by the syslog run

# -----------------------------------------------------------------------------
# funcs.awk — shared helpers, loaded into BOTH generation passes via -f.
# -----------------------------------------------------------------------------
# WHY a separate file: syslog and auth.log must format timestamps identically
# and share the same random-token vocabulary. Duplicating the code invites drift
# between the two files, which would break the correlation exercise.
cat > "$WORK/funcs.awk" <<'FUNCS_EOF'
# --- calendar ---------------------------------------------------------------
# We cannot use strftime(): that is a gawk extension and Debian ships mawk.
# So we do the civil-date arithmetic by hand from a fixed base month/day.
function init_cal() {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mname, " ")
    split("31 28 31 30 31 30 31 31 30 31 30 31", mlen, " ")
}

# ts(t) -> "Mon DD HH:MM:SS" where t is seconds since base_mo/base_dom 00:00:00.
# Day-of-month is SPACE padded to width 2 ("Jul  4"), which is what real syslog
# does and is a classic thing naive split()-based parsers get wrong.
function ts(t,    d, rem, h, m, s, mo, dom) {
    d   = int(t / 86400)
    rem = t % 86400
    h   = int(rem / 3600)
    m   = int((rem % 3600) / 60)
    s   = rem % 60
    mo  = base_mo
    dom = base_dom + d
    while (dom > mlen[mo]) {
        dom -= mlen[mo]
        mo++
        if (mo > 12) mo = 1
    }
    return sprintf("%s %2d %02d:%02d:%02d", mname[mo], dom, h, m, s)
}

# --- small random helpers ----------------------------------------------------
function rnd(lo, hi) { return lo + int(rand() * (hi - lo + 1)) }

# split() produces 1-based arrays, hence the 1+ offset.
function pick(arr, n) { return arr[1 + int(rand() * n)] }

# Documentation/TEST-NET ranges only (RFC 5737). Never bake a real routable IP
# into a teaching artifact — a candidate might reflexively try to contact it.
function rip(    r) {
    r = rnd(1, 3)
    if (r == 1) return sprintf("203.0.113.%d",  rnd(2, 250))
    if (r == 2) return sprintf("198.51.100.%d", rnd(2, 250))
    return sprintf("192.0.2.%d", rnd(2, 250))
}

function lanip() { return sprintf("10.20.%d.%d", rnd(0, 20), rnd(2, 250)) }

function ruser(    u, n) {
    n = split("admin root oracle postgres test ubuntu deploy git jenkins pi guest backup svc_scan", u, " ")
    return u[1 + int(rand() * n)]
}

# expand() substitutes tokens so no two emitted lines look copy-pasted:
#   @N@  -> a plausible pid / sector / counter
#   @S@  -> a small number (bus, port index, retry count)
#   @IP@ -> external IP     @LAN@ -> internal IP     @U@ -> username
# sub() replaces the FIRST match only, so the loops handle multi-token lines.
function expand(s) {
    while (index(s, "@N@"))   sub(/@N@/,   rnd(200, 29999), s)
    while (index(s, "@S@"))   sub(/@S@/,   rnd(1, 9), s)
    while (index(s, "@IP@"))  sub(/@IP@/,  rip(), s)
    while (index(s, "@LAN@")) sub(/@LAN@/, lanip(), s)
    while (index(s, "@U@"))   sub(/@U@/,   ruser(), s)
    return s
}
FUNCS_EOF

# -----------------------------------------------------------------------------
# bulk.awk — generates one chronologically-ordered syslog stream.
# -----------------------------------------------------------------------------
# Called twice: once for the live /var/log/syslog, once for the older rotated
# generation. Parameters via -v so the same code serves both.
cat > "$WORK/bulk.awk" <<'BULK_EOF'
# ---------------------------------------------------------------------------
# Background noise. ~85% of the file. Deliberately boring, deliberately varied.
# A good parser must not choke on any of these; a good analyst must ignore them.
# ---------------------------------------------------------------------------
function init_noise() {
    NNOISE = 0
    NOISE[++NNOISE] = "systemd[1]: Started Daily apt upgrade and clean activities."
    NOISE[++NNOISE] = "systemd[1]: Starting Cleanup of Temporary Directories..."
    NOISE[++NNOISE] = "systemd[1]: Finished Cleanup of Temporary Directories."
    NOISE[++NNOISE] = "systemd[1]: apt-daily.service: Succeeded."
    NOISE[++NNOISE] = "systemd[1]: Reloading."
    NOISE[++NNOISE] = "systemd[1]: Started Session @S@ of user @U@."
    NOISE[++NNOISE] = "systemd[1]: session-@S@.scope: Succeeded."
    NOISE[++NNOISE] = "systemd[1]: Started User Manager for UID @N@."
    NOISE[++NNOISE] = "systemd-logind[@N@]: New session @S@ of user @U@."
    NOISE[++NNOISE] = "systemd-logind[@N@]: Removed session @S@."
    NOISE[++NNOISE] = "systemd-logind[@N@]: Watching system buttons on /dev/input/event0 (Power Button)"
    NOISE[++NNOISE] = "CRON[@N@]: (root) CMD (   cd / && run-parts --report /etc/cron.hourly)"
    NOISE[++NNOISE] = "CRON[@N@]: (root) CMD ([ -x /usr/lib/php/sessionclean ] && /usr/lib/php/sessionclean)"
    NOISE[++NNOISE] = "CRON[@N@]: (@U@) CMD (/usr/local/bin/collect-metrics.sh >/dev/null 2>&1)"
    NOISE[++NNOISE] = "cron[@N@]: (*system*) RELOAD (/etc/crontab)"
    NOISE[++NNOISE] = "dbus-daemon[@N@]: [system] Successfully activated service 'org.freedesktop.hostname1'"
    NOISE[++NNOISE] = "dbus-daemon[@N@]: [system] Activating via systemd: service name='org.freedesktop.timedate1' unit='dbus-org.freedesktop.timedate1.service'"
    NOISE[++NNOISE] = "dbus-daemon[@N@]: [system] Successfully activated service 'org.freedesktop.systemd1'"
    NOISE[++NNOISE] = "sshd[@N@]: Accepted publickey for @U@ from @LAN@ port @N@ ssh2: RSA SHA256:9xQm2vKpL0dR3sTfUvWxYz1AbCdEfGhIjKlMnOpQrSt"
    NOISE[++NNOISE] = "sshd[@N@]: pam_unix(sshd:session): session opened for user @U@(uid=@S@)"
    NOISE[++NNOISE] = "sshd[@N@]: pam_unix(sshd:session): session closed for user @U@"
    NOISE[++NNOISE] = "sshd[@N@]: Received disconnect from @LAN@ port @N@:11: disconnected by user"
    NOISE[++NNOISE] = "rsyslogd: [origin software=\"rsyslogd\" swVersion=\"8.2302.0\"] rsyslogd was HUPed"
    NOISE[++NNOISE] = "rsyslogd: action 'action-0-builtin:omfile' resumed (module 'builtin:omfile')"
    NOISE[++NNOISE] = "kernel: audit: type=1400 audit(@N@.@S@:@S@): apparmor=\"STATUS\" operation=\"profile_load\" profile=\"unconfined\""
    NOISE[++NNOISE] = "kernel: device vethA@S@B@S@ entered promiscuous mode"
    NOISE[++NNOISE] = "kernel: br0: port @S@(veth@N@) entered forwarding state"
    NOISE[++NNOISE] = "kernel: EXT4-fs (sda1): re-mounted. Opts: (null). Quota mode: none."
    NOISE[++NNOISE] = "kernel: random: crng init done"
    NOISE[++NNOISE] = "apt-daily[@N@]: Reading package lists..."
    NOISE[++NNOISE] = "apt-daily[@N@]: Building dependency tree..."
    NOISE[++NNOISE] = "unattended-upgrade[@N@]: Initial blacklist: "
    NOISE[++NNOISE] = "unattended-upgrade[@N@]: Packages that will be upgraded: (none)"
    NOISE[++NNOISE] = "snapfetch[@N@]: refresh check completed, next check in 6h"
    NOISE[++NNOISE] = "snapfetch[@N@]: no updates available for track stable"
    NOISE[++NNOISE] = "chronyd[@N@]: Selected source @LAN@ (pool.ntp.org)"
    NOISE[++NNOISE] = "chronyd[@N@]: System clock wrong by 0.0000@S@ seconds, adjustment started"
    NOISE[++NNOISE] = "collectd[@N@]: plugin_dispatch_values: interval = @N@.000000"
    NOISE[++NNOISE] = "nginx[@N@]: @LAN@ - - \"GET /health HTTP/1.1\" 200 @N@ \"-\" \"kube-probe/1.28\""
    NOISE[++NNOISE] = "nginx[@N@]: @LAN@ - - \"POST /api/v1/telemetry HTTP/1.1\" 204 0 \"-\" \"agent/2.4.1\""
    NOISE[++NNOISE] = "dockerd[@N@]: time=\"2026-07-0@S@T@S@2:1@S@:0@S@Z\" level=info msg=\"container health status changed\""
    NOISE[++NNOISE] = "systemd-timesyncd[@N@]: Contacted time server @LAN@:123 (ntp.ubuntu.com)."
    NOISE[++NNOISE] = "kernel: perf: interrupt took too long (@N@ > @N@), lowering kernel.perf_event_max_sample_rate"
    NOISE[++NNOISE] = "postfix/qmgr[@N@]: @N@ABCDEF: from=<noreply@lab.local>, size=@N@, nrcpt=1 (queue active)"
}

# ---------------------------------------------------------------------------
# The four error classes. These are the SIGNAL the learner has to find.
# Each class has multiple phrasings on purpose — a parser keyed to one exact
# string will undercount, which is exactly the mistake worth making in a lab.
# ---------------------------------------------------------------------------
function init_errors() {
    # Class 1 — NIC link flaps. Note eth1: never eth0 (SSH lifeline).
    NNIC = 0
    ENIC[++NNIC] = "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Down"
    ENIC[++NNIC] = "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: Rx/Tx"
    ENIC[++NNIC] = "kernel: IPv6: ADDRCONF(NETDEV_UP): eth1: link is not ready"
    ENIC[++NNIC] = "NetworkManager[@N@]: <warn>  [@N@.@N@] device (eth1): carrier lost, deferring activation"
    ENIC[++NNIC] = "systemd-networkd[@N@]: eth1: Lost carrier"
    ENIC[++NNIC] = "systemd-networkd[@N@]: eth1: Gained carrier"
    ENIC[++NNIC] = "dhclient[@N@]: DHCPDISCOVER on eth1 to 255.255.255.255 port 67 interval @S@"
    ENIC[++NNIC] = "dhclient[@N@]: No DHCPOFFERS received."
    ENIC[++NNIC] = "kernel: e1000e 0000:00:1f.6 eth1: Reset adapter unexpectedly"
    # Explicit down/up bookends for each flap episode.
    NIC_DOWN = "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Down"
    NIC_UP   = "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: Rx/Tx"

    # Class 2 — TCP transmission timeouts / connection-table exhaustion.
    NTCP = 0
    ETCP[++NTCP] = "kernel: TCP: request_sock_TCP: Possible SYN flooding on port 443. Sending cookies.  Check SNMP counters."
    ETCP[++NTCP] = "kernel: TCP: request_sock_TCP: Possible SYN flooding on port 22. Sending cookies.  Check SNMP counters."
    ETCP[++NTCP] = "kernel: nf_conntrack: nf_conntrack: table full, dropping packet"
    ETCP[++NTCP] = "kernel: TCP: out of memory -- consider tuning tcp_mem"
    ETCP[++NTCP] = "kernel: net_ratelimit: @N@ callbacks suppressed"
    ETCP[++NTCP] = "kernel: TCP: retransmit timeout on @LAN@:@N@ after @S@ retries"
    ETCP[++NTCP] = "kernel: TCP: peer @IP@:@N@ unexpectedly shrunk window (repaired)"
    ETCP[++NTCP] = "haproxy[@N@]: backend api-backend has no server available!"
    ETCP[++NTCP] = "haproxy[@N@]: Server api-backend/node@S@ is DOWN, reason: Layer4 timeout, check duration: @N@ms"
    ETCP[++NTCP] = "nginx[@N@]: upstream timed out (110: Connection timed out) while connecting to upstream, client: @IP@"

    # Class 3 — USB peripheral disconnect / re-enumeration.
    NUSB = 0
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: USB disconnect, device number @S@"
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: new high-speed USB device number @S@ using ehci-pci"
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: device descriptor read/64, error -110"
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: device not accepting address @S@, error -32"
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: reset high-speed USB device number @S@ using ehci-pci"
    EUSB[++NUSB] = "kernel: ftdi_sio ttyUSB0: FTDI USB Serial Device converter now disconnected from ttyUSB0"
    EUSB[++NUSB] = "kernel: ftdi_sio 2-1.@S@:1.0: FTDI USB Serial Device converter detected"
    EUSB[++NUSB] = "kernel: usb 2-1.@S@: Product: FT232R USB UART"
    EUSB[++NUSB] = "mtp-probe: checking bus 2, device @S@: \"/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1\""
    EUSB[++NUSB] = "kernel: hub 2-1:1.0: cannot reset port @S@ (err = -32)"

    # Class 4 — OOM killer and disk I/O errors (host is genuinely sick here).
    NOOM = 0
    EOOM[++NOOM] = "kernel: Out of memory: Killed process @N@ (python3) total-vm:@N@kB, anon-rss:@N@kB, file-rss:0kB"
    EOOM[++NOOM] = "kernel: Out of memory: Killed process @N@ (collectd) total-vm:@N@kB, anon-rss:@N@kB, file-rss:0kB"
    EOOM[++NOOM] = "kernel: oom_reaper: reaped process @N@ (python3), now anon-rss:0kB, file-rss:0kB"
    EOOM[++NOOM] = "kernel: python3 invoked oom-killer: gfp_mask=0x@S@00cc0(GFP_KERNEL), order=0, oom_score_adj=0"
    EOOM[++NOOM] = "kernel: blk_update_request: I/O error, dev sda, sector @N@@N@ op 0x1:(WRITE) flags 0x800 phys_seg 1"
    EOOM[++NOOM] = "kernel: blk_update_request: critical medium error, dev sda, sector @N@@N@ op 0x0:(READ)"
    EOOM[++NOOM] = "kernel: EXT4-fs error (device sda1): ext4_find_entry:1455: inode #@N@: comm rsyslogd: reading directory lblock 0"
    EOOM[++NOOM] = "kernel: EXT4-fs (sda1): Remounting filesystem read-only"
    EOOM[++NOOM] = "kernel: sd 0:0:0:0: [sda] tag#@S@ FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_SENSE"
    EOOM[++NOOM] = "systemd[1]: collectd.service: Main process exited, code=killed, status=9/KILL"

}

function err_line(cls) {
    if (cls == "NIC") return pick(ENIC, NNIC)
    if (cls == "TCP") return pick(ETCP, NTCP)
    if (cls == "USB") return pick(EUSB, NUSB)
    return pick(EOOM, NOOM)
}

# ---------------------------------------------------------------------------
# Burst planning.
# WHY: uniformly-scattered errors are unlearnable. Real incidents arrive in
# episodes. We lay 12 episodes across the file, spaced but jittered, each
# 40-120 lines wide, and inside an episode ~35% of lines belong to that class.
# The remaining 65% stays background noise so bursts still have to be *found*,
# not just seen.
# ---------------------------------------------------------------------------
function plan_bursts(    k, center, half, jitter) {
    # Interleaved on purpose so classes do not appear in a tidy repeating cycle.
    split("NIC TCP NIC USB OOM NIC TCP USB NIC OOM TCP USB", border, " ")
    NB = 12
    jitter = int(lines / 60)
    if (jitter < 1) jitter = 1
    for (k = 1; k <= NB; k++) {
        center = int(lines * (k - 0.5) / NB) + rnd(-jitter, jitter)
        half   = rnd(20, 60)
        bs[k]  = center - half
        be[k]  = center + half

        # ORDER MATTERS. Widen first, THEN clamp to the file end. Doing the
        # clamp first lets the +10 widening push be[k] past the last line, so
        # the `i == be[k]` test in the main loop never fires — which for a NIC
        # burst means a link-down with no matching link-up and, worse, no
        # window record for auth.log. The correlation would silently vanish.
        if (bs[k] < 2)         bs[k] = 2
        if (be[k] <= bs[k])    be[k] = bs[k] + 10
        if (be[k] > lines - 1) be[k] = lines - 1
        if (bs[k] >= be[k])    bs[k] = be[k] - 1

        # Forbid overlap with the previous burst. burst_at() returns the FIRST
        # matching burst, so an overlap makes the later burst's start index
        # unreachable -> nstart[k] never set -> a malformed (2-field) window
        # record that auth.awk silently discards. Safe at the default 11000
        # lines, but SYSLOG_LINES is a documented knob and small values
        # (e.g. 500) overlap heavily.
        if (k > 1 && bs[k] <= be[k - 1]) bs[k] = be[k - 1] + 1
        if (bs[k] >= be[k])              be[k] = bs[k] + 10
        if (be[k] > lines - 1)           be[k] = lines - 1

        bc[k] = border[k]
    }
}

# Returns the first burst covering line i, or 0. Correctness depends on
# plan_bursts() guaranteeing non-overlapping ranges (see above).
function burst_at(i,    k) {
    for (k = 1; k <= NB; k++)
        if (i >= bs[k] && i <= be[k]) return k
    return 0
}

# ---------------------------------------------------------------------------
# Malformed lines. Real logs are never clean; a parser that assumes a rigid
# 5-field split will crash or silently drop data. We plant ~16 landmines.
# ---------------------------------------------------------------------------
function plan_malformed(    k, idx) {
    NMAL = 16
    for (k = 1; k <= NMAL; k++) {
        idx = rnd(int(lines * 0.05), int(lines * 0.95))
        mal[idx] = 1
    }
}

# A DELIBERATE DESIGN DECISION — do not "fix" this back:
# We embed odd control bytes (\001 SOH, \007 BEL, \033 ESC) but NOT a true
# 0x00 NUL. A single NUL anywhere in the file makes GNU grep declare
# "Binary file syslog matches" and suppress ALL output for the entire file.
# That would mean the learner's first exploratory `grep` silently returns
# nothing for everything after the NUL, and any reference counts a grader
# computes with grep would be quietly wrong. That corrupts the exercise
# instead of teaching it. The control bytes below exercise exactly the same
# parser robustness (non-printable handling, encoding surprises) while
# leaving the standard CLI toolchain usable.
function malformed_line(n,    r) {
    r = n % 8
    if (r == 0) return "Jul 99 99:99:99 " HOST " kernel: [ 9999.999999] <<TRUNCATED"
    if (r == 1) return "####-##-## ??:??:?? " HOST " cron[@N@]: garbage timestamp on this entry"
    if (r == 2) return ts(t) " " HOST " message with no process field at all, just prose"
    if (r == 3) return ts(t) " " HOST " sshd: pam_unix(sshd:auth): missing pid brackets on this one"
    if (r == 4) return ts(t) " " HOST " kernel: \033[1;31mALERT\033[0m escape sequence leaked into the log"
    if (r == 5) return ts(t)                      # truncated mid-line: no host, no message
    if (r == 6) return ""                         # a bare empty line
    return ts(t) " " HOST " collectd[@N@]: value=\001\007 control chars embedded\033[0m"
}

BEGIN {
    init_cal(); init_noise(); init_errors()
    srand(seed)
    HOST = host
    plan_bursts()
    if (malformed) plan_malformed()

    t = rnd(0, 300)   # small random offset so the file does not start at 00:00:00

    for (i = 1; i <= lines; i++) {
        # Advance the clock 1-14s per line. Monotonic => the file is already
        # chronologically ordered and never needs sorting.
        t += rnd(1, 14)

        k = burst_at(i)
        if (k > 0) {
            if (bc[k] == "NIC" && i == bs[k]) {
                line = NIC_DOWN
                nstart[k] = t
            } else if (bc[k] == "NIC" && i == be[k]) {
                line = NIC_UP
                # Hand this window to the auth.log pass so its failed-login
                # burst lands in the SAME timestamp range. This is the join the
                # learner is meant to discover.
                # Defence in depth: only emit a window if we actually recorded
                # its start. An unset nstart[k] would stringify to "" and
                # produce a 2-field record that auth.awk drops on the floor —
                # losing the correlation with no error anywhere.
                if (nicfile != "" && (k in nstart)) {
                    # Build the record first. `print a, b, f() > file` makes
                    # awk's grammar ambiguous between redirection and a
                    # comparison; a single pre-built string removes all doubt.
                    winrec = nstart[k] " " t " " rip()
                    print winrec > nicfile
                }
            } else if (rand() < 0.35) {
                line = err_line(bc[k])
            } else {
                line = pick(NOISE, NNOISE)
            }
        } else {
            line = pick(NOISE, NNOISE)
        }

        print ts(t) " " HOST " " expand(line)

        if (malformed && (i in mal))
            print expand(malformed_line(i))
    }

    if (spanfile != "") print t > spanfile
    if (nicfile != "")  close(nicfile)
    if (spanfile != "") close(spanfile)
}
BULK_EOF

# -----------------------------------------------------------------------------
# auth.awk — the companion file that makes the exercise a CORRELATION problem.
# -----------------------------------------------------------------------------
# Reads the NIC-flap windows emitted by the syslog pass and packs failed-auth
# bursts into exactly those windows. Baseline sshd noise is spread across the
# whole span so the bursts are not trivially obvious from line density alone.
#
# Output is "<epoch>\t<line>" and is sorted numerically downstream — sorting
# syslog-style timestamps as text is incorrect and this file is NOT generated
# in monotonic order (noise and bursts are produced in separate loops).
cat > "$WORK/auth.awk" <<'AUTH_EOF'
function init_auth() {
    NAN = 0
    ANOISE[++NAN] = "sshd[@N@]: Accepted publickey for @U@ from @LAN@ port @N@ ssh2: ED25519 SHA256:kQ7fLm2xNp9RsTvWyZ0aBcDeFgHiJkLmNoPqRsTuVwX"
    ANOISE[++NAN] = "sshd[@N@]: Accepted publickey for fae from @LAN@ port @N@ ssh2: RSA SHA256:aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5aB6c"
    ANOISE[++NAN] = "sshd[@N@]: pam_unix(sshd:session): session opened for user @U@(uid=@S@) by (uid=0)"
    ANOISE[++NAN] = "sshd[@N@]: pam_unix(sshd:session): session closed for user @U@"
    ANOISE[++NAN] = "sshd[@N@]: Received disconnect from @LAN@ port @N@:11: disconnected by user"
    ANOISE[++NAN] = "sshd[@N@]: Disconnected from user @U@ @LAN@ port @N@"
    ANOISE[++NAN] = "sudo:     @U@ : TTY=pts/@S@ ; PWD=/home/@U@ ; USER=root ; COMMAND=/usr/bin/journalctl -xe"
    ANOISE[++NAN] = "sudo: pam_unix(sudo:session): session opened for user root(uid=0) by @U@(uid=@N@)"
    ANOISE[++NAN] = "sudo: pam_unix(sudo:session): session closed for user root"
    ANOISE[++NAN] = "CRON[@N@]: pam_unix(cron:session): session opened for user root(uid=0) by (uid=0)"
    ANOISE[++NAN] = "CRON[@N@]: pam_unix(cron:session): session closed for user root"
    ANOISE[++NAN] = "systemd-logind[@N@]: New session @S@ of user @U@."
    ANOISE[++NAN] = "sshd[@N@]: Server listening on 0.0.0.0 port 22."

    NAF = 0
    AFAIL[++NAF] = "sshd[@N@]: Failed password for invalid user @U@ from @ATT@ port @N@ ssh2"
    AFAIL[++NAF] = "sshd[@N@]: Failed password for root from @ATT@ port @N@ ssh2"
    AFAIL[++NAF] = "sshd[@N@]: Invalid user @U@ from @ATT@ port @N@"
    AFAIL[++NAF] = "sshd[@N@]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=@ATT@"
    AFAIL[++NAF] = "sshd[@N@]: pam_unix(sshd:auth): check pass; user unknown"
    AFAIL[++NAF] = "sshd[@N@]: error: maximum authentication attempts exceeded for root from @ATT@ port @N@ ssh2 [preauth]"
    AFAIL[++NAF] = "sshd[@N@]: Disconnecting authenticating user root @ATT@ port @N@: Too many authentication failures [preauth]"
    AFAIL[++NAF] = "sshd[@N@]: Connection closed by authenticating user @U@ @ATT@ port @N@ [preauth]"
    AFAIL[++NAF] = "sshd[@N@]: Received disconnect from @ATT@ port @N@:11: Bye Bye [preauth]"
    AFAIL[++NAF] = "sshd[@N@]: banner exchange: Connection from @ATT@ port @N@: invalid format"
}

BEGIN {
    init_cal(); init_auth()
    srand(seed + 7)
    HOST = host

    # --- read the NIC-flap windows produced by the syslog pass ---------------
    nn = 0
    while ((getline ln < nicfile) > 0) {
        if (split(ln, a, " ") >= 3) {
            nn++; ws[nn] = a[1] + 0; we[nn] = a[2] + 0; wip[nn] = a[3]
        }
    }
    close(nicfile)

    # --- baseline noise across the entire span -------------------------------
    for (i = 0; i < normal; i++) {
        t = rnd(0, span)
        print t "\t" ts(t) " " HOST " " expand(pick(ANOISE, NAN))
    }

    # --- failure bursts, pinned inside the NIC-flap windows ------------------
    # One attacker IP per window: repetition is what makes the correlation
    # legible once the learner groups by (time window, source IP).
    for (k = 1; k <= nn; k++) {
        cnt = rnd(30, 70)
        for (j = 0; j < cnt; j++) {
            t = rnd(ws[k], we[k])
            line = pick(AFAIL, NAF)
            gsub(/@ATT@/, wip[k], line)
            print t "\t" ts(t) " " HOST " " expand(line)
        }
    }
}
AUTH_EOF

# -----------------------------------------------------------------------------
# Validate the tunables BEFORE touching anything on disk.
# -----------------------------------------------------------------------------
# These are documented env-var knobs. A typo (SYSLOG_LINES=1oooo) must fail here
# and leave the existing dataset intact, not halfway through generation with the
# old logs already truncated.
for var in SEED SYSLOG_LINES ROTATED_LINES; do
    eval "val=\$$var"
    case "$val" in
        ''|*[!0-9]*) echo "[FAIL] $var must be a positive integer (got '$val')"; exit 1 ;;
    esac
done
if [ "$SYSLOG_LINES" -lt 10000 ]; then
    echo "[FAIL] SYSLOG_LINES must be >= 10000 (lab requirement); got $SYSLOG_LINES"
    exit 1
fi

# =============================================================================
# ATOMIC WRITE STRATEGY
# =============================================================================
# All three passes generate into $WORK and are only moved into place at the very
# end, after every pass has succeeded. Writing directly to /var/log would mean a
# failed awk or gzip leaves a truncated syslog and — worse — destroys the last
# good syslog.1.gz, which the lab brief explicitly tells the learner to parse.
# A half-generated dataset is harder to notice than a missing one.
# =============================================================================

# =============================================================================
# Pass 1 — the live syslog (with malformed lines + NIC window capture)
# =============================================================================
: > "$NICFILE"
: > "$SPANFILE"

awk -f "$WORK/funcs.awk" -f "$WORK/bulk.awk" \
    -v lines="$SYSLOG_LINES" \
    -v seed="$SEED" \
    -v base_mo=7 -v base_dom=4 \
    -v host="$HOSTNAME_TAG" \
    -v nicfile="$NICFILE" \
    -v spanfile="$SPANFILE" \
    -v malformed=1 \
    </dev/null > "$WORK/syslog"
SYS_RC=$?

SPAN="$(cat "$SPANFILE" 2>/dev/null)"
[ -z "${SPAN:-}" ] && SPAN=86400

# =============================================================================
# Pass 2 — the rotated, gzipped older generation (/var/log/syslog.1.gz)
# =============================================================================
# Different seed and an EARLIER base date (Jun 28) so the rotated file genuinely
# predates the live one. A parser that ignores rotation will miss these bursts
# entirely — which is the point.
awk -f "$WORK/funcs.awk" -f "$WORK/bulk.awk" \
    -v lines="$ROTATED_LINES" \
    -v seed="$((SEED + 101))" \
    -v base_mo=6 -v base_dom=28 \
    -v host="$HOSTNAME_TAG" \
    -v nicfile="" \
    -v spanfile="" \
    -v malformed=1 \
    </dev/null > "$WORK/syslog.1"
ROT_RC=$?

gzip -c "$WORK/syslog.1" > "$WORK/syslog.1.gz"
GZ_RC=$?

# =============================================================================
# Pass 3 — auth.log, time-correlated with the NIC windows from pass 1
# =============================================================================
# Sort numerically on the epoch key, then strip it. Sorting the human-readable
# timestamp as text would misorder single-digit days ("Jul  4" vs "Jul 14").
AUTH_NORMAL="${AUTH_NORMAL:-2600}"
awk -f "$WORK/funcs.awk" -f "$WORK/auth.awk" \
    -v seed="$SEED" \
    -v base_mo=7 -v base_dom=4 \
    -v host="$HOSTNAME_TAG" \
    -v nicfile="$NICFILE" \
    -v span="$SPAN" \
    -v normal="$AUTH_NORMAL" \
    </dev/null | sort -n | cut -f2- > "$WORK/auth.log"
AUTH_RC=$?   # NOTE: this is the awk status ONLY because `set -o pipefail` is
             # active above; without it this would capture cut's status. (M4)

# =============================================================================
# Validate, then commit atomically
# =============================================================================
NIC_WINDOWS=$(wc -l < "$NICFILE" 2>/dev/null | tr -d ' ')
gen_lines=$(wc -l < "$WORK/syslog" 2>/dev/null | tr -d ' ')

FATAL=0
[ "${SYS_RC:-1}"  -ne 0 ] && { echo "[FAIL] syslog generation (rc=$SYS_RC)";   FATAL=1; }
[ "${ROT_RC:-1}"  -ne 0 ] && { echo "[FAIL] rotated generation (rc=$ROT_RC)";  FATAL=1; }
[ "${GZ_RC:-1}"   -ne 0 ] && { echo "[FAIL] gzip (rc=$GZ_RC)";                 FATAL=1; }
[ "${AUTH_RC:-1}" -ne 0 ] && { echo "[FAIL] auth.log generation (rc=$AUTH_RC)"; FATAL=1; }
[ "${gen_lines:-0}" -lt 10000 ] && { echo "[FAIL] syslog only ${gen_lines:-0} lines"; FATAL=1; }

# The correlation between auth.log and the NIC-flap windows IS the exercise.
# Zero windows yields an auth.log of pure background noise with nothing to
# correlate — a lab that looks fine and cannot be solved. Fail loudly instead
# of shipping a candidate a dataset with no answer in it.
if [ "${NIC_WINDOWS:-0}" -lt 2 ]; then
    echo "[FAIL] only ${NIC_WINDOWS:-0} NIC-flap window(s) recorded — auth.log correlation would be absent"
    FATAL=1
fi

if [ "$FATAL" -ne 0 ]; then
    echo "[FAIL] generation aborted; existing logs in $LOGDIR left untouched."
    exit 1
fi

# Commit. Only now do the real files change.
mv -f "$WORK/syslog"      "$LOGDIR/syslog"      || exit 1
mv -f "$WORK/syslog.1.gz" "$LOGDIR/syslog.1.gz" || exit 1
mv -f "$WORK/auth.log"    "$LOGDIR/auth.log"    || exit 1

# =============================================================================
# Permissions — the learner runs as `fae` and must not need sudo to READ.
# =============================================================================
chmod 0644 "$LOGDIR/syslog" "$LOGDIR/syslog.1.gz" "$LOGDIR/auth.log" 2>/dev/null

# =============================================================================
# Summary
# =============================================================================
# Deliberately reports COUNTS ONLY. It never names the error classes or their
# strings — discovering those is the assignment.
sys_lines=$(wc -l < "$LOGDIR/syslog" 2>/dev/null | tr -d ' ')
auth_lines=$(wc -l < "$LOGDIR/auth.log" 2>/dev/null | tr -d ' ')
rot_lines=$(gzip -dc "$LOGDIR/syslog.1.gz" 2>/dev/null | wc -l | tr -d ' ')

echo "=== gen-syslog.sh summary ==="
echo "  $LOGDIR/syslog        ${sys_lines:-0} lines"
echo "  $LOGDIR/syslog.1.gz   ${rot_lines:-0} lines (gzipped)"
echo "  $LOGDIR/auth.log      ${auth_lines:-0} lines"
echo "  correlation windows: $NIC_WINDOWS"
echo "  seed=$SEED  (set GEN_SEED=... to reshuffle)"
echo "  note: some lines are intentionally malformed. that is not a bug."
echo "============================="

# All failure paths already exited above, before anything was committed.
exit 0
