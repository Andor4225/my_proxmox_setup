#!/bin/bash
# =============================================================================
# Lab 3 — "The Raw Log Playground"  :: in-container setup
# =============================================================================
#
# TARGET:  CT 205 `lab-logs`, Debian 12 privileged LXC
#          eth0 = 192.168.10.205/24, gw 192.168.10.1, bridge vmbr0. No lab NIC.
#
# DEPLOY (run these on the Proxmox HOST, not here):
#     pct push 205 setup.sh      /root/setup.sh      --perms 755
#     pct push 205 gen-syslog.sh /root/gen-syslog.sh --perms 755
#     pct exec 205 -- /root/setup.sh
#
# =============================================================================
# ############################  SACRED INVARIANT  ###########################
# eth0, its IP address, and the default route via 192.168.10.1 are the
# learner's ONLY path in — SSH arrives over Tailscale via the Proxmox subnet
# router. This script MUST NOT touch networking. There is deliberately no
# `ip`, `ifup`, `dhclient`, `nmcli`, `systemctl restart networking`, no edit
# of /etc/network/interfaces, and no firewall rule anywhere below.
# The only listener we touch is sshd, and only to ENABLE it on port 22.
# If you extend this script: adding a network command here bricks the lab.
# ###########################################################################
#
# WHAT THIS LAB IS
#   An EXERCISE, not a break/fix ticket. Nothing in this container is broken.
#   The container hosts a large, messy, realistic body of log data. The learner
#   SSHes in and writes a Python script FROM SCRATCH to parse it.
#
# WHY `set -e` IS ABSENT
#   A single non-fatal failure (e.g. an optional package missing from the
#   mirror) must not abort setup before the verification block runs. We want
#   the [OK]/[FAIL] report every time — a half-configured container that tells
#   you what is missing beats a script that dies silently at line 40.
#
# IDEMPOTENT: safe to re-run. Re-running regenerates the logs from scratch.
# =============================================================================

set -uo pipefail

echo "=== Lab 3 setup: The Raw Log Playground (CT 205 lab-logs) ==="

# -----------------------------------------------------------------------------
# 1. Wait for network before apt
# -----------------------------------------------------------------------------
# Fresh LXC containers need a moment before the bridge/gateway is usable. Firing
# `apt-get update` immediately is the single most common cause of a failed
# container build. We ping the GATEWAY (not 8.8.8.8) because that proves the
# lab's own L2/L3 path is up without depending on internet egress.
echo "[*] Waiting for network..."
for i in $(seq 1 15); do
    ping -c1 -W1 192.168.10.1 >/dev/null 2>&1 && break
    sleep 2
done
ping -c1 -W1 192.168.10.1 >/dev/null 2>&1 \
    && echo "[*] Gateway reachable." \
    || echo "[WARN] Gateway not answering ICMP — continuing anyway (apt may fail)."

# -----------------------------------------------------------------------------
# 2. Locale — suppress the perl/dpkg locale spam
# -----------------------------------------------------------------------------
# Debian 12 LXC templates emit "perl: warning: Setting locale failed" on nearly
# every apt operation. Cosmetic, but it buries real errors in the deploy output
# and makes the container feel broken to a candidate who pokes around.
echo "[*] Configuring locale..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y locales >/dev/null 2>&1
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
# Only export the locale if locale-gen actually succeeded. Exporting
# LC_ALL=en_US.UTF-8 for a locale that was never generated (e.g. apt could not
# reach the mirror, so `locales` is not installed) makes every subsequent
# command emit "setlocale: cannot change locale" — turning the occasional spam
# this block exists to suppress into unconditional spam.
if locale-gen >/dev/null 2>&1; then
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
fi

# -----------------------------------------------------------------------------
# 3. Packages
# -----------------------------------------------------------------------------
# python3 is the point of the lab — the learner writes their parser in it.
# gzip/less/grep/vim are the manual-inspection toolkit they will reach for
# before they start scripting. curl is standard for utility containers here.
echo "[*] Installing packages..."
apt-get install -y \
    curl \
    python3 \
    gzip \
    less \
    vim \
    grep \
    openssh-server \
    sudo \
    >/dev/null 2>&1
APT_RC=$?
[ "$APT_RC" -eq 0 ] && echo "[*] Packages installed." \
                    || echo "[WARN] apt-get returned $APT_RC — check verification below."

# -----------------------------------------------------------------------------
# 4. The `fae` user (Field Application Engineer candidate)
# -----------------------------------------------------------------------------
echo "[*] Creating user 'fae'..."
if ! id fae >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "Field Application Engineer" fae
fi
usermod -aG sudo fae >/dev/null 2>&1
# `adm` is the traditional Debian log-reading group. Belt-and-braces alongside
# the world-readable mode we set on the log files in step 8.
usermod -aG adm fae >/dev/null 2>&1

# Seed fae's authorized_keys from root's, so whoever can already reach this
# container over Tailscale can log in as the unprivileged lab user without a
# password round-trip. Only if root actually has keys — copying an empty file
# would just create a confusing 0-byte authorized_keys.
if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 0700 -o fae -g fae /home/fae/.ssh
    install -m 0600 -o fae -g fae /root/.ssh/authorized_keys /home/fae/.ssh/authorized_keys
    echo "[*] Seeded /home/fae/.ssh/authorized_keys from root."
else
    echo "[*] /root/.ssh/authorized_keys empty or absent — password fallback only."
fi

# Fallback password. This is a throwaway lab container on an internal VLAN with
# no inbound exposure; a known password is the right trade for "candidate can
# always get in". Do NOT copy this pattern to anything that faces a network.
# DELIBERATELY NO ROOT PASSWORD. sshd runs PermitRootLogin prohibit-password so
# it would never work over SSH anyway, and this CT sits at 192.168.10.205 — a
# range whitelisted to the Kali VLAN and reachable across the whole tailnet.
# Root console access remains available from the Proxmox host: pct enter 205
echo 'fae:faelab123'  | chpasswd

# -----------------------------------------------------------------------------
# 5. SSH — port 22 only
# -----------------------------------------------------------------------------
# Explicitly NOT changing the port. The learner's inbound path is already
# established on 22; touching it risks the invariant at the top of this file.
#
# Note on socket activation: Debian 12 (bookworm) ships ssh.socket but enables
# ssh.service — socket activation is the default on Debian 13 (trixie) and
# Ubuntu 22.10+, NOT here. Under socket activation `is-active ssh` reports
# inactive for an idle unit, so we check both and never restart a working sshd
# on the strength of a misleading probe.
echo "[*] Enabling ssh..."
systemctl enable --now ssh >/dev/null 2>&1
if ! systemctl is-active ssh >/dev/null 2>&1 && \
   ! systemctl is-active ssh.socket >/dev/null 2>&1; then
    systemctl restart ssh >/dev/null 2>&1
fi

# rsyslog, if present, will happily append its own live entries to
# /var/log/syslog. Stop it so the dataset stays stable for the lab's duration.
if systemctl list-unit-files 2>/dev/null | grep -q '^rsyslog\.service'; then
    echo "[*] Stopping rsyslog so it does not overwrite the synthetic logs..."
    systemctl disable --now rsyslog >/dev/null 2>&1
fi

# Disabling rsyslog is NOT sufficient on its own. logrotate is a SEPARATE
# systemd timer, and /etc/logrotate.d/rsyslog stays on disk after the service
# is disabled. Debian 12 rotates /var/log/syslog weekly with `compress`, so a
# container deployed more than a week before a candidate sits down would have:
#   - /var/log/syslog       rotated away to near-empty
#   - /var/log/syslog.1.gz  OVERWRITTEN with the rotated live syslog
# That destroys the older-generation file the brief explicitly tells the learner
# to parse, and the lab silently becomes unsolvable with nothing to flag it.
# Both the config and the timer go.
echo "[*] Disabling log rotation (would destroy the synthetic dataset)..."
rm -f /etc/logrotate.d/rsyslog
systemctl disable --now logrotate.timer >/dev/null 2>&1

# -----------------------------------------------------------------------------
# 6. Install and run the log generator
# -----------------------------------------------------------------------------
echo "[*] Installing gen-syslog.sh..."
if [ -f /root/gen-syslog.sh ]; then
    install -m 0755 /root/gen-syslog.sh /usr/local/sbin/gen-syslog.sh
elif [ -f "$(dirname "$0")/gen-syslog.sh" ]; then
    install -m 0755 "$(dirname "$0")/gen-syslog.sh" /usr/local/sbin/gen-syslog.sh
else
    echo "[FAIL] gen-syslog.sh not found at /root/ or alongside setup.sh."
    echo "       pct push 205 gen-syslog.sh /root/gen-syslog.sh --perms 755"
fi

if [ -x /usr/local/sbin/gen-syslog.sh ]; then
    echo "[*] Generating logs (this takes a few seconds)..."
    /usr/local/sbin/gen-syslog.sh
fi

# -----------------------------------------------------------------------------
# 7. Optional live-tail trickle service — INSTALLED BUT DISABLED
# -----------------------------------------------------------------------------
# Rationale: a static file is the right default. Deterministic line counts mean
# the learner can verify their parser's arithmetic, and a grader can compare two
# candidates against identical data. But `tail -f` practice is genuinely useful,
# so the capability ships — opt-in, never auto-started.
echo "[*] Installing log-trickle.service (disabled by default)..."

cat > /usr/local/sbin/log-trickle.sh <<'TRICKLE_EOF'
#!/bin/bash
# Appends one realistic syslog line to /var/log/syslog every few seconds.
# Purpose: gives the learner a moving target for `tail -f` / streaming-parser
# practice. Started only when log-trickle.service is explicitly enabled.
set -uo pipefail
LOGFILE=/var/log/syslog
HOST=lab-logs

MSGS=(
  "systemd[1]: Started Session %d of user fae."
  "CRON[%d]: (root) CMD (   cd / && run-parts --report /etc/cron.hourly)"
  "dbus-daemon[%d]: [system] Successfully activated service 'org.freedesktop.hostname1'"
  "sshd[%d]: Received disconnect from 10.20.4.9 port 52344:11: disconnected by user"
  "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Down"
  "kernel: e1000e 0000:00:1f.6 eth1: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: Rx/Tx"
  "kernel: TCP: request_sock_TCP: Possible SYN flooding on port 443. Sending cookies."
  "kernel: usb 2-1.4: USB disconnect, device number %d"
  "kernel: blk_update_request: I/O error, dev sda, sector %d op 0x1:(WRITE)"
  "chronyd[%d]: Selected source 10.20.0.7 (pool.ntp.org)"
  "collectd[%d]: plugin_dispatch_values: interval = 10.000000"
)
# NOTE: every template above carries AT MOST ONE %d, and exactly one argument is
# supplied below. bash printf REUSES the format string until all arguments are
# consumed, so a one-%d template given two args renders TWICE, concatenated
# ("CRON[8421]: ...CRON[19022]: ..."). That is not a realistic syslog line and
# would confuse anyone practising tail -f parsing against it. Keep it 1:1.

while true; do
    tmpl="${MSGS[$RANDOM % ${#MSGS[@]}]}"
    # shellcheck disable=SC2059  # the template intentionally carries the format
    body="$(printf "$tmpl" "$((RANDOM % 29000 + 200))" 2>/dev/null)"
    printf '%s %s %s\n' "$(date '+%b %e %H:%M:%S')" "$HOST" "$body" >> "$LOGFILE"
    sleep $((RANDOM % 5 + 3))
done
TRICKLE_EOF
chmod 0755 /usr/local/sbin/log-trickle.sh

cat > /etc/systemd/system/log-trickle.service <<'UNIT_EOF'
[Unit]
Description=Lab 3 optional live log trickle (tail -f practice)
Documentation=file:/root/LAB_BRIEF.txt
# Only writes a local file; no ordering dependency beyond a mounted filesystem.
# (Ordering After= the same target that WantedBy= pulls us into is a common
# copy-paste error — avoided deliberately.)
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/log-trickle.sh
Restart=on-failure
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload >/dev/null 2>&1
# Explicitly disabled, explicitly not started. This is a requirement, not an
# oversight — see the rationale comment above.
# `--now` matters: plain `disable` would leave a previously-enabled trickle
# still RUNNING on a re-run, appending to the syslog we just regenerated while
# verification below cheerfully reports it as "disabled".
systemctl disable --now log-trickle.service >/dev/null 2>&1

# -----------------------------------------------------------------------------
# 8. Log readability for the `fae` user
# -----------------------------------------------------------------------------
# The exercise is parsing, not privilege escalation. Making the candidate
# prefix every read with sudo adds friction and teaches nothing.
echo "[*] Setting log permissions..."
chmod 0755 /var/log
for f in /var/log/syslog /var/log/syslog.1.gz /var/log/auth.log; do
    [ -f "$f" ] && chmod 0644 "$f" && chown root:adm "$f"
done

# -----------------------------------------------------------------------------
# 9. The assignment — LAB_BRIEF.txt and motd
# -----------------------------------------------------------------------------
# Deliberately vague about SPECIFICS. It names the deliverable and the files,
# but never the error strings, never the class names, never the counts.
# Discovering those IS the exercise; a brief that lists them reduces the lab to
# transcription.
echo "[*] Writing lab brief..."

cat > /root/LAB_BRIEF.txt <<'BRIEF_EOF'
===============================================================================
 LAB 3 — THE RAW LOG PLAYGROUND
===============================================================================

This is an EXERCISE, not a support ticket. Nothing on this host is broken.
There is no service to restart and no config to fix. The logs are the work.

-------------------------------------------------------------------------------
 ASSIGNMENT
-------------------------------------------------------------------------------

Write a Python script, from scratch, that:

  1. Parses /var/log/syslog
  2. Isolates the distinct classes of ERROR present in it
  3. Counts each class
  4. Correlates those errors with the events in /var/log/auth.log

Use the standard library only. No log-parsing packages, no pip install, no
regex library beyond `re`. Writing the parser is the point.

-------------------------------------------------------------------------------
 THE DATA
-------------------------------------------------------------------------------

  /var/log/syslog        the current log
  /var/log/syslog.1.gz   the previous, rotated log (yes, it counts)
  /var/log/auth.log      authentication events over the same period

Standard syslog line format:

  Mon DD HH:MM:SS hostname process[pid]: message

-------------------------------------------------------------------------------
 WHAT YOU SHOULD KNOW GOING IN
-------------------------------------------------------------------------------

  * These are real-world-shaped logs. Some lines are malformed: bad
    timestamps, truncated records, missing fields, stray control characters.
    Your script must survive them and keep going. Crashing on line 6,412 is a
    failing answer. So is silently dropping records you could not parse —
    count what you skip.

  * The errors are not evenly distributed. Think about WHEN things happened,
    not just HOW MANY times. A flat total is the least interesting number you
    can produce from this dataset.

  * syslog and auth.log describe the same machine over the same hours. Read
    them together.

  * The rotated file is older than the live one. Ordering matters.

-------------------------------------------------------------------------------
 WHAT "DONE" LOOKS LIKE
-------------------------------------------------------------------------------

  * A count per error class, and you can defend why those are the classes.
  * A statement of when each class occurred — grouped, not listed.
  * At least one correlation between syslog and auth.log that you can explain
    in a sentence, with the evidence to back it.
  * A note on how many lines you could not parse, and why.

-------------------------------------------------------------------------------
 HOUSEKEEPING
-------------------------------------------------------------------------------

  Login:  ssh fae@192.168.10.205        (password fallback: faelab123)
  Work in /home/fae. The log files are world-readable; you do not need sudo
  to read them.

  Regenerate the dataset (same seed -> byte-identical data, so any counts you
  recorded stay valid; set GEN_SEED to reshuffle, which WILL invalidate them):
      sudo /usr/local/sbin/gen-syslog.sh

  Optional — a live trickle of new log lines for `tail -f` practice.
  OFF by default, on purpose (a static file keeps your counts reproducible):
      sudo systemctl enable --now log-trickle.service     # turn on
      sudo systemctl disable --now log-trickle.service    # turn off

  Note: trickled lines are stamped with the CURRENT wall-clock date, while the
  static dataset is stamped with the date it was generated. If you enable the
  trickle you will see a gap between the two. That gap is an artifact of the
  lab, not a finding — do not report it as one.

  DO NOT reconfigure networking on this container. eth0 and the default route
  via 192.168.10.1 are your only way in.

===============================================================================
BRIEF_EOF
chmod 0644 /root/LAB_BRIEF.txt

cat > /etc/motd <<'MOTD_EOF'

  ===========================================================================
   LAB 3 — THE RAW LOG PLAYGROUND                            host: lab-logs
  ===========================================================================

   This is an exercise. Nothing here is broken — do not go looking for a
   service to fix.

   ASSIGNMENT
     Write a Python script, from scratch, that parses /var/log/syslog,
     isolates the classes of error it contains, counts them, and correlates
     them against /var/log/auth.log.

   YOUR DATA
     /var/log/syslog        current
     /var/log/syslog.1.gz   rotated, older, still counts
     /var/log/auth.log      same machine, same hours

   NOTES
     Some lines are malformed on purpose. Do not crash; do count what you
     skip. The errors are clustered in time, not evenly spread — when they
     happened matters as much as how many. Standard library only.

   Full brief: /root/LAB_BRIEF.txt  (readable copy: sudo cat)
   Optional live tail practice: sudo systemctl enable --now log-trickle

   Do not reconfigure networking. eth0 is your only way in.
  ===========================================================================

MOTD_EOF
chmod 0644 /etc/motd

# A copy the unprivileged user can read without sudo.
install -m 0644 -o fae -g fae /root/LAB_BRIEF.txt /home/fae/LAB_BRIEF.txt 2>/dev/null

# =============================================================================
# Verification
# =============================================================================
# Every setup script in this lab ends with an explicit pass/fail report. It has
# repeatedly caught partial deployments that otherwise look successful.
echo ""
echo "=== Verification ==="

# FAILS is the script's exit status. Without it the final `echo` would make
# `pct exec 205 -- /root/setup.sh` return 0 even when python3 is missing or
# syslog has 40 lines — a broken deploy that reports success. A human reads
# this output today, but the exit code is what any wrapper or OpenClaw check
# will consume.
FAILS=0
ok()   { echo "[OK]   $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 \
    && ok "python3 present ($(python3 --version 2>&1))" \
    || fail "python3 missing"

if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    ok "ssh active"
else
    fail "ssh not active"
fi

id fae >/dev/null 2>&1 \
    && ok "user fae exists" \
    || fail "user fae missing"

if [ -f /var/log/syslog ]; then
    SYSCOUNT=$(wc -l < /var/log/syslog | tr -d ' ')
    if [ "${SYSCOUNT:-0}" -ge 10000 ]; then
        ok "/var/log/syslog exists ($SYSCOUNT lines, >= 10000)"
    else
        fail "/var/log/syslog only $SYSCOUNT lines (need >= 10000)"
    fi
else
    fail "/var/log/syslog missing"
fi

[ -f /var/log/auth.log ] \
    && ok "/var/log/auth.log exists ($(wc -l < /var/log/auth.log | tr -d ' ') lines)" \
    || fail "/var/log/auth.log missing"

[ -f /var/log/syslog.1.gz ] \
    && ok "/var/log/syslog.1.gz exists ($(gzip -dc /var/log/syslog.1.gz | wc -l | tr -d ' ') lines)" \
    || fail "/var/log/syslog.1.gz missing"

# Must be BOTH installed AND disabled. Either half alone is a failure.
if [ -f /etc/systemd/system/log-trickle.service ]; then
    # NB: `systemctl is-enabled` EXITS NON-ZERO for a disabled unit -- that is by
    # design. Piping it into grep under `set -o pipefail` makes the pipeline
    # inherit that non-zero status even when grep matches, so a correctly
    # disabled service reported as a FAILURE. Capture the state first, then
    # compare -- no pipe, no pipefail interaction.
    TRICKLE_STATE="$(systemctl is-enabled log-trickle.service 2>/dev/null || true)"
    if [ "$TRICKLE_STATE" = "disabled" ] || [ "$TRICKLE_STATE" = "masked" ]; then
        ok "log-trickle.service installed and disabled"
    else
        fail "log-trickle.service installed but NOT disabled (state: ${TRICKLE_STATE:-unknown})"
    fi
else
    fail "log-trickle.service not installed"
fi

# Confirms the log-permissions step actually worked from the candidate's POV.
su -s /bin/sh -c 'head -n1 /var/log/syslog >/dev/null 2>&1' fae \
    && ok "fae can read /var/log/syslog without sudo" \
    || fail "fae cannot read /var/log/syslog"

[ -f /root/LAB_BRIEF.txt ] \
    && ok "/root/LAB_BRIEF.txt written" \
    || fail "/root/LAB_BRIEF.txt missing"

echo "===================="
echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "Lab 3 ready.  ssh fae@192.168.10.205   (fallback password: faelab123)"
    exit 0
else
    echo "Lab 3 setup completed with $FAILS failure(s) — see [FAIL] lines above."
    exit 1
fi
