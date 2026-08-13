#!/usr/bin/env bash
# =============================================================================
# Linux Privilege Escalation CTF Challenge - Setup Script
# Target: Debian 12 LXC container on Proxmox
# Run as root: bash setup.sh
# =============================================================================

set -euo pipefail

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; exit 1; }

# --- Preflight checks ---
if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must be run as root."
fi

if ! grep -qi 'debian' /etc/os-release 2>/dev/null; then
    warn "This script is designed for Debian 12. Proceeding anyway..."
fi

log "Starting CTF challenge setup..."

# =============================================================================
# 1. Install required packages
# =============================================================================
log "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    openssh-server \
    vim \
    nano \
    gcc \
    net-tools \
    cron \
    sudo \
    procps \
    findutils \
    tar \
    curl \
    wget \
    file \
    less \
    > /dev/null 2>&1

log "Packages installed."

# =============================================================================
# 2. Create ctfplayer user
# =============================================================================
log "Creating ctfplayer user..."
if id ctfplayer &>/dev/null; then
    warn "User ctfplayer already exists, resetting password."
else
    useradd -m -s /bin/bash ctfplayer
fi
echo "ctfplayer:ctfplayer123" | chpasswd

# =============================================================================
# 3. Configure SSH for password auth
# =============================================================================
log "Configuring SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Ensure password authentication is enabled
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"

# Add explicit override at end if not already present
if ! grep -q "^Match User ctfplayer" "$SSHD_CONFIG"; then
    cat >> "$SSHD_CONFIG" <<'SSHEOF'

# CTF: Allow password auth for ctfplayer
Match User ctfplayer
    PasswordAuthentication yes
SSHEOF
fi

# Generate host keys if missing (common in fresh LXC containers)
ssh-keygen -A 2>/dev/null || true

systemctl enable ssh 2>/dev/null || true
systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true

log "SSH configured."

# =============================================================================
# 4. Place flags
# =============================================================================
log "Placing flags..."
mkdir -p /root

cat > /root/flag1.txt <<'EOF'
FLAG{su1d_b1n4ry_3xpl01t_ez}
EOF

cat > /root/flag2.txt <<'EOF'
FLAG{cr0n_j0b_wr1t4bl3_scr1pt}
EOF

cat > /root/flag3.txt <<'EOF'
FLAG{sud0_m1sc0nf1g_v1m_sh3ll}
EOF

cat > /root/flag4.txt <<'EOF'
FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}
EOF

chmod 600 /root/flag1.txt /root/flag2.txt /root/flag3.txt /root/flag4.txt

# Verification file
cat > /root/flags.txt <<'EOF'
=== CTF Flag Verification ===
Flag 1 (SUID Binary):          FLAG{su1d_b1n4ry_3xpl01t_ez}
Flag 2 (Cron Job):             FLAG{cr0n_j0b_wr1t4bl3_scr1pt}
Flag 3 (Sudo Misconfiguration): FLAG{sud0_m1sc0nf1g_v1m_sh3ll}
Flag 4 (Writable /etc/passwd): FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}
EOF
chmod 600 /root/flags.txt

log "Flags placed."

# =============================================================================
# 5. Flag 1 - SUID Binary (PATH Hijack)
# =============================================================================
log "Setting up Flag 1: SUID binary with PATH hijack..."

# Create the vulnerable C program
SUID_SRC=$(mktemp /tmp/statuscheck_XXXXXX.c)
cat > "$SUID_SRC" <<'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    printf("=== System Status Check ===\n");
    printf("Checking system log...\n\n");
    // Vulnerable: uses relative path — susceptible to PATH hijack
    system("cat /var/log/status.log");
    printf("\n=== Check complete ===\n");
    return 0;
}
CSRC

gcc -o /usr/local/bin/statuscheck "$SUID_SRC" -Wall
rm -f "$SUID_SRC"

# Set SUID root.
# ORDER MATTERS: chown CLEARS the setuid/setgid bits (POSIX). Doing chown after
# chmod left this binary as -rwxr-xr-x and made the flag unobtainable, while the
# script still reported success. Ownership first, permissions last.
chown root:root /usr/local/bin/statuscheck
chmod 4755 /usr/local/bin/statuscheck

# Verify the bit actually survived (lxc-gotchas.md #8/#10) — a configuration
# check would pass here regardless; this is the functional one.
if [[ "$(stat -c '%A' /usr/local/bin/statuscheck)" == -rws* ]]; then
    echo "[OK] statuscheck is SUID root"
else
    echo "[FAIL] statuscheck is NOT SUID — privesc flag will be unobtainable"
    # || true: this stat is the last command of the else branch and therefore
    # the exit status of the whole `if`; without it a non-zero here would abort
    # under set -e. The final verify block re-checks this authoritatively.
    stat -c '%A %U:%G' /usr/local/bin/statuscheck || true
fi

# Create the fake log file the program reads
cat > /var/log/status.log <<'EOF'
[OK] System uptime: 47 days
[OK] Disk usage: 34%
[OK] Memory: 62% utilized
[OK] Services: all nominal
[OK] Last backup: 2026-03-30 02:00:00
EOF
chmod 644 /var/log/status.log

log "Flag 1 configured."

# =============================================================================
# 6. Flag 2 - Cron Job with World-Writable Script
# =============================================================================
log "Setting up Flag 2: Cron job with writable script..."

mkdir -p /opt/scripts

cat > /opt/scripts/backup.sh <<'BACKUP'
#!/bin/bash
# Automated backup script - runs every 2 minutes
tar czf /tmp/backup.tar.gz /var/log/ 2>/dev/null
BACKUP

# The vulnerability: world-writable. chown before chmod as a uniform rule —
# 0777 carries no setuid bit so the order is harmless today, but keeping every
# chmod/chown pair in the same order means no future edit (e.g. 0777 -> 4777)
# silently reintroduces the chown-clears-setuid bug.
chown root:root /opt/scripts/backup.sh
chmod 0777 /opt/scripts/backup.sh

# Install the cron job in root's crontab.
#
# This MUST NOT be the old one-liner:
#   (crontab -l 2>/dev/null | grep -v '...'; echo "$CRON_LINE") | crontab -
# On a fresh container root has no crontab, so `crontab -l` exits 1 and `grep -v`
# exits 1 on empty input. Under `set -euo pipefail` that killed the SUBSHELL
# before `echo` ever ran, and pipefail propagated it out — so the whole setup
# script aborted here and flags 2, 3 and 4 were never configured at all, while
# `crontab -` was simultaneously fed empty input. Build the file explicitly.
CRON_LINE="*/2 * * * * /bin/bash /opt/scripts/backup.sh"
TMP_CRON=$(mktemp)
{ crontab -l 2>/dev/null || true; } | grep -Fv '/opt/scripts/backup.sh' > "$TMP_CRON" || true
echo "$CRON_LINE" >> "$TMP_CRON"
# Guarded, not bare: a failing `crontab` install must not abort the script and
# silently drop flags 3/4 + the verify block. Let the failure surface as a
# [FAIL] in the tally (which now controls the exit code) instead.
if ! crontab "$TMP_CRON"; then
    warn "Failed to install root crontab — flag 2 may be unobtainable."
fi
rm -f "$TMP_CRON"

# Also add to /etc/crontab for discoverability. NOTE: this means backup.sh runs
# from BOTH root's crontab and /etc/crontab — twice every 2 minutes. That is
# intentional (two places for the player to find it); a player's injected
# payload will therefore also fire twice, which is expected, not a broken exploit.
if ! grep -q '/opt/scripts/backup.sh' /etc/crontab 2>/dev/null; then
    echo "*/2 * * * * root /bin/bash /opt/scripts/backup.sh" >> /etc/crontab
fi

# Start cron
systemctl enable cron 2>/dev/null || true
systemctl start cron 2>/dev/null || service cron start 2>/dev/null || true

log "Flag 2 configured."

# =============================================================================
# 7. Flag 3 - Sudo Misconfiguration (vim escape)
# =============================================================================
log "Setting up Flag 3: Sudo misconfiguration with vim..."

# Create the log file vim is allowed to edit
mkdir -p /var/log
cat > /var/log/app.log <<'EOF'
2026-03-30 10:15:23 [INFO] Application started successfully
2026-03-30 10:15:24 [INFO] Listening on port 8080
2026-03-30 10:16:01 [WARN] High memory usage detected (78%)
2026-03-30 10:17:45 [INFO] User login: admin from 192.168.10.50
2026-03-30 10:18:02 [ERROR] Failed to connect to database: timeout
2026-03-30 10:18:03 [INFO] Retrying database connection...
2026-03-30 10:18:04 [INFO] Database connection established
2026-03-30 10:30:00 [INFO] Scheduled cleanup task completed
EOF
chmod 644 /var/log/app.log

# Create sudoers entry — ctfplayer can run vim on this file as root, no password
cat > /etc/sudoers.d/ctfplayer <<'SUDOERS'
# CTF: Allow ctfplayer to edit application log with vim
ctfplayer ALL=(root) NOPASSWD: /usr/bin/vim /var/log/app.log
SUDOERS
chmod 440 /etc/sudoers.d/ctfplayer

# Validate sudoers syntax
if ! visudo -c -f /etc/sudoers.d/ctfplayer >/dev/null 2>&1; then
    err "Sudoers file has syntax errors! Aborting."
fi

log "Flag 3 configured."

# =============================================================================
# 8. Flag 4 - Writable /etc/passwd
# =============================================================================
log "Setting up Flag 4: Writable /etc/passwd..."

# Add ctfplayer to its own group (should already exist)
usermod -aG ctfplayer ctfplayer 2>/dev/null || true

# Guarantee the group exists before chown depends on it. On the supported
# "user already exists" path (see the useradd block) the group is not
# guaranteed, and a bare `chown root:ctfplayer` would abort the whole script.
getent group ctfplayer >/dev/null || groupadd ctfplayer

# Make /etc/passwd group-writable by ctfplayer's group
chown root:ctfplayer /etc/passwd
chmod 664 /etc/passwd

log "Flag 4 configured."

# =============================================================================
# 9. Red Herrings
# =============================================================================
log "Planting red herrings..."

# Non-exploitable SUID binaries (standard system binaries that are normally SUID)
# These are already SUID on most systems, but ensure they exist
for bin in /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp; do
    if [[ -f "$bin" ]]; then
        chmod u+s "$bin" 2>/dev/null || true
    fi
done

# Custom non-exploitable SUID binary
DECOY_SRC=$(mktemp /tmp/sysinfo_XXXXXX.c)
cat > "$DECOY_SRC" <<'CSRC'
#include <stdio.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname buf;
    if (uname(&buf) == 0) {
        printf("System: %s %s %s\n", buf.sysname, buf.release, buf.machine);
    }
    printf("Status: OK\n");
    return 0;
}
CSRC
gcc -o /usr/local/bin/sysinfo "$DECOY_SRC" -Wall
# chown BEFORE chmod — chown clears the setuid bit. With the old order this
# decoy was not actually SUID, so the red herring silently did not exist.
chown root:root /usr/local/bin/sysinfo
chmod 4755 /usr/local/bin/sysinfo
rm -f "$DECOY_SRC"

# Another decoy SUID
DECOY2_SRC=$(mktemp /tmp/healthcheck_XXXXXX.c)
cat > "$DECOY2_SRC" <<'CSRC'
#include <stdio.h>
#include <time.h>

int main(void) {
    time_t now = time(NULL);
    printf("Health Check Report\n");
    printf("Timestamp: %s", ctime(&now));
    printf("CPU: OK\n");
    printf("Memory: OK\n");
    printf("Disk: OK\n");
    return 0;
}
CSRC
gcc -o /usr/local/bin/healthcheck "$DECOY2_SRC" -Wall
# chown BEFORE chmod — see the note on sysinfo above.
chown root:root /usr/local/bin/healthcheck
chmod 4755 /usr/local/bin/healthcheck
rm -f "$DECOY2_SRC"

# Fake interesting files in /tmp
cat > /tmp/credentials.bak <<'EOF'
# Old credentials file - DO NOT USE
# admin:admin123 (changed 2025-12-01)
# These have been rotated and are no longer valid
db_user=app_readonly
db_pass=N0tR34lP4ssw0rd!
EOF
chmod 644 /tmp/credentials.bak

cat > /tmp/.secret_notes.txt <<'EOF'
TODO: remember to rotate SSH keys
TODO: check if backup script is still running
NOTE: the admin panel is at port 8443 (disabled)
NOTE: old API key was revoked on 2026-01-15
EOF
chmod 644 /tmp/.secret_notes.txt

mkdir -p /tmp/.cache
cat > /tmp/.cache/session_token <<'EOF'
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6ImRlY295IiwiYWRtaW4iOmZhbHNlLCJpYXQiOjE1MTYyMzkwMjJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
EOF
chmod 644 /tmp/.cache/session_token

# Fake .bash_history hints for root (player won't see this unless they escalate)
cat > /root/.bash_history <<'EOF'
apt update
systemctl restart nginx
cat /opt/scripts/backup.sh
vim /etc/crontab
useradd -m ctfplayer
passwd ctfplayer
chmod 777 /opt/scripts/backup.sh
visudo
cat /root/flags.txt
EOF
chmod 600 /root/.bash_history

log "Red herrings planted."

# =============================================================================
# 10. Player README
# =============================================================================
log "Creating player README..."

# Guard the home dir like every other mkdir in this script — on the
# "user already exists" path it may not be present, and a bare redirect into a
# missing directory would abort before the verify block runs.
mkdir -p /home/ctfplayer
cat > /home/ctfplayer/README.txt <<'README'
===============================================================================
  LINUX PRIVILEGE ESCALATION CTF CHALLENGE
===============================================================================

  Welcome, operator.

  You've gained initial access to this system as a low-privilege user.

  YOUR MISSION:
    Escalate your privileges to root and find all 4 flags located in /root/.

  FLAGS:
    - /root/flag1.txt
    - /root/flag2.txt
    - /root/flag3.txt
    - /root/flag4.txt

  DIFFICULTY:
    Flag 1: Easy
    Flag 2: Medium
    Flag 3: Medium
    Flag 4: Hard

  RULES:
    - All escalation paths are intentional vulnerabilities
    - Standard Linux enumeration techniques are all you need
    - No kernel exploits required
    - No brute forcing required
    - Tools available: vim, nano, gcc, find, etc.

  HINTS (if you get stuck):
    - What binaries have unusual permissions?
    - Are there any scheduled tasks?
    - What can you run with elevated privileges?
    - Are any critical system files misconfigured?

  Good luck.

===============================================================================
README
chown ctfplayer:ctfplayer /home/ctfplayer/README.txt
chmod 644 /home/ctfplayer/README.txt

log "Player README created."

# =============================================================================
# 11. Final hardening and cleanup
# =============================================================================
log "Final configuration..."

# Ensure ctfplayer cannot read root's directory directly
chmod 700 /root

# Clean up apt cache to save space
apt-get clean -qq

# Remove this setup script's traces from bash history
history -c 2>/dev/null || true
cat /dev/null > /root/.bash_history 2>/dev/null || true

# Re-create the decoy history
cat > /root/.bash_history <<'EOF'
apt update
systemctl restart nginx
cat /opt/scripts/backup.sh
vim /etc/crontab
useradd -m ctfplayer
passwd ctfplayer
chmod 777 /opt/scripts/backup.sh
visudo
cat /root/flags.txt
EOF
chmod 600 /root/.bash_history

# =============================================================================
# 12. Verification
# =============================================================================
echo ""
log "============================================="
log "  CTF Challenge Setup Complete"
log "============================================="
echo ""

PASS=0
FAIL=0

verify() {
    local desc="$1"
    local check="$2"
    if eval "$check" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[PASS]${NC} $desc"
        # NOT ((PASS++)): post-increment evaluates to the OLD value, so when
        # PASS is 0 the arithmetic result is 0, which bash reports as exit
        # status 1 — and under `set -e` that killed the script on the very
        # first passing check, making a fully-configured container look failed.
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $desc"
        FAIL=$((FAIL + 1))
    fi
}

verify "ctfplayer user exists"          "id ctfplayer"
verify "Flag 1 exists"                  "test -f /root/flag1.txt"
verify "Flag 2 exists"                  "test -f /root/flag2.txt"
verify "Flag 3 exists"                  "test -f /root/flag3.txt"
verify "Flag 4 exists"                  "test -f /root/flag4.txt"
verify "statuscheck is SUID"            "test -u /usr/local/bin/statuscheck"
verify "backup.sh is world-writable"    "test -w /opt/scripts/backup.sh && stat -c '%a' /opt/scripts/backup.sh | grep -qx '777'"
verify "sudoers entry exists"           "visudo -c -f /etc/sudoers.d/ctfplayer"
verify "vim binary present (flag 3)"    "test -x /usr/bin/vim"
verify "/etc/passwd is group-writable"  "stat -c '%a' /etc/passwd | grep -qxE '66[46]'"
verify "cron is running"                "pgrep -x cron"
verify "SSH is running"                 "pgrep -x sshd"
verify "sshd config valid"              "sshd -t"
verify "Cron job installed"             "crontab -l 2>/dev/null | grep -q backup.sh"
verify "Decoy SUID sysinfo"            "test -u /usr/local/bin/sysinfo"
verify "Decoy SUID healthcheck"        "test -u /usr/local/bin/healthcheck"
verify "Player README exists"           "test -f /home/ctfplayer/README.txt"

echo ""
log "Results: ${PASS} passed, ${FAIL} failed"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    log "All checks passed. Challenge is ready."
    echo ""
    echo -e "  ${YELLOW}Connect with:${NC}  ssh ctfplayer@<container-ip>"
    echo -e "  ${YELLOW}Password:${NC}      ctfplayer123"
    echo ""
else
    warn "Some checks failed. Review the output above."
    # Exit non-zero so deploy.sh's "setup.sh exited non-zero" guard actually
    # fires. Without this the script always exits 0, the guard can never trip on
    # a verification failure, and a half-configured challenge (e.g. the SUID bit
    # not sticking) ships looking successful — exactly the class of silent loss
    # this whole session was spent hunting. The verify block is the sole
    # authority on success; make its verdict the exit code.
    exit 1
fi
