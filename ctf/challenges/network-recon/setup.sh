#!/usr/bin/env bash
###############################################################################
# Network Reconnaissance & Service Exploitation CTF Challenge
# Target: Debian 12 LXC container on Proxmox
# Difficulty: Intermediate
#
# Flags:
#   1 (Easy)   - FTP Anonymous Access   : FLAG{4n0nym0us_ftp_l00t}
#   2 (Medium) - Non-Standard Port Svc  : FLAG{h1dd3n_p0rt_s3rv1c3}
#   3 (Hard)   - Port Knocking + SSH    : FLAG{p0rt_kn0ck_s3cr3t_d00r}
#
# Usage: bash setup.sh   (run as root inside the container)
###############################################################################

set -euo pipefail

# ---------- guard ----------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[!] This script must be run as root." >&2
    exit 1
fi

echo "=============================================="
echo " CTF Challenge Setup - Network Recon"
echo "=============================================="

# ---------- packages -------------------------------------------------------
echo "[*] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    vsftpd \
    nmap \
    net-tools \
    iptables \
    knockd \
    openssh-server \
    python3 \
    tar \
    gzip \
    procps \
    sudo \
    > /dev/null

echo "[+] Packages installed."

###############################################################################
# FLAG 1 - FTP Anonymous Access
# FLAG{4n0nym0us_ftp_l00t}
###############################################################################
echo "[*] Configuring Flag 1 - FTP Anonymous Access..."

# Create FTP directory structure
mkdir -p /srv/ftp/pub/.hidden

# Decoy: readme.txt
cat > /srv/ftp/pub/readme.txt << 'READEOF'
=============================================
  MegaCorp Public File Share
=============================================

Welcome to the MegaCorp shared file repository.

NOTICE: This is a PUBLIC file share.
Do not store sensitive data here.
All files are accessible without authentication.

For internal resources, contact IT department.

Last updated: 2024-09-15
=============================================
READEOF

# Decoy: notes.txt (hint for Flag 3 - port knocking)
cat > /srv/ftp/pub/notes.txt << 'NOTESEOF'
-- IT Admin Notes --

TODO:
- Rotate service credentials (overdue!)
- Update firewall rules on prod servers
- Check backup integrity

Reminder: emergency access sequence is 7-8-9 (thousands). Don't forget!
That hidden door saved us last time the main auth went down.

- J.
NOTESEOF

# Decoy: backup_old.tar.gz (contains auth token for Flag 2)
TMPDIR_BACKUP=$(mktemp -d)
mkdir -p "${TMPDIR_BACKUP}/megacorp-config"

cat > "${TMPDIR_BACKUP}/megacorp-config/debug_console.conf" << 'CONFEOF'
# MegaCorp Debug Console Configuration
# Version: 2.1
# Last modified: 2024-03-12

[service]
port = 31337
bind_address = 0.0.0.0
max_connections = 10

[auth]
# Authentication token for debug access
# TODO: rotate this token - it has been the same since 2024
auth_token = MEGACORP-2024

[logging]
log_level = WARNING
log_file = /var/log/megacorp/debug.log
CONFEOF

cat > "${TMPDIR_BACKUP}/megacorp-config/README" << 'BKREADEOF'
MegaCorp Internal Configuration Backup
Date: 2024-03-12
Contents: Debug console configuration
BKREADEOF

tar -czf /srv/ftp/pub/backup_old.tar.gz -C "${TMPDIR_BACKUP}" megacorp-config
rm -rf "${TMPDIR_BACKUP}"

# Flag 1 file
cat > /srv/ftp/pub/.hidden/credentials.txt << 'FLAG1EOF'
=============================================
  MegaCorp Internal Credentials
=============================================

System: Backup Authentication Service
User:   svc_backup
Pass:   Pr0d_B4ckup_2024!

FLAG{4n0nym0us_ftp_l00t}

NOTE: If you found this, we have a serious
misconfiguration. Contact security@megacorp.io
=============================================
FLAG1EOF

# Set ownership
chown -R ftp:ftp /srv/ftp/pub/
chmod -R 755 /srv/ftp/pub/
chmod 755 /srv/ftp/pub/.hidden

# Configure vsftpd
cat > /etc/vsftpd.conf << 'VSFTPDEOF'
# vsftpd configuration - MegaCorp
listen=YES
listen_ipv6=NO
anonymous_enable=YES
local_enable=NO
write_enable=NO
anon_root=/srv/ftp
no_anon_password=YES
hide_ids=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
connect_from_port_20=YES
ftpd_banner=MegaCorp FTP Service
seccomp_sandbox=NO
VSFTPDEOF

systemctl enable vsftpd
systemctl restart vsftpd

echo "[+] Flag 1 configured."

###############################################################################
# FLAG 2 - Custom TCP Service on Port 31337
# FLAG{h1dd3n_p0rt_s3rv1c3}
###############################################################################
echo "[*] Configuring Flag 2 - Custom TCP Service..."

mkdir -p /opt/megacorp

cat > /opt/megacorp/debug_console.py << 'PYEOF'
#!/usr/bin/env python3
"""MegaCorp Internal Debug Console v2.1 - CTF Challenge Service."""

import socketserver
import threading
import signal
import sys

AUTH_TOKEN = "MEGACORP-2024"
FLAG = "FLAG{h1dd3n_p0rt_s3rv1c3}"
BANNER = "MegaCorp Internal Debug Console v2.1\r\n"
PROMPT = "debug> "

HELP_TEXT = (
    "Available commands:\r\n"
    "  help    - Show this help message\r\n"
    "  status  - Show system status\r\n"
    "  debug   - Access debug interface (requires auth token)\r\n"
    "  exit    - Close connection\r\n"
)


class DebugHandler(socketserver.StreamRequestHandler):
    """Handle individual client connections to the debug console."""

    timeout = 120  # seconds before auto-disconnect

    def handle(self):
        """Process commands from the connected client."""
        client = f"{self.client_address[0]}:{self.client_address[1]}"
        print(f"[+] Connection from {client}")
        try:
            self.wfile.write(BANNER.encode())
            self.wfile.write(
                b"Type 'help' for available commands.\r\n"
            )
            self.wfile.flush()

            while True:
                self.wfile.write(PROMPT.encode())
                self.wfile.flush()

                raw = self.rfile.readline()
                if not raw:
                    break

                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue

                response = self._process_command(line)
                if response is None:
                    self.wfile.write(b"Goodbye.\r\n")
                    self.wfile.flush()
                    break

                self.wfile.write((response + "\r\n").encode())
                self.wfile.flush()

        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        finally:
            print(f"[-] Disconnected {client}")

    def _process_command(self, line):
        """Parse and execute a single command. Return None to disconnect."""
        parts = line.split(None, 1)
        cmd = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""

        if cmd == "help":
            return HELP_TEXT
        elif cmd == "status":
            return "All systems operational."
        elif cmd == "debug":
            if arg.strip() == AUTH_TOKEN:
                return (
                    "=== DEBUG MODE ACTIVE ===\r\n"
                    f"Auth token accepted.\r\n"
                    f"System flag: {FLAG}\r\n"
                    "=== END DEBUG ==="
                )
            elif arg.strip():
                return "Access denied. Invalid auth token."
            else:
                return "Access denied. Requires auth token."
        elif cmd == "exit" or cmd == "quit":
            return None
        else:
            return f"Unknown command: '{cmd}'. Type 'help' for commands."


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    """TCP server that handles each connection in a separate thread."""
    allow_reuse_address = True
    daemon_threads = True


def main():
    """Start the debug console service."""
    host = "0.0.0.0"
    port = 31337
    server = ThreadedTCPServer((host, port), DebugHandler)

    def shutdown_handler(signum, frame):
        print("\n[*] Shutting down debug console...")
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print(f"[*] MegaCorp Debug Console listening on {host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

chmod 755 /opt/megacorp/debug_console.py

# Create a dedicated service user
useradd --system --no-create-home --shell /usr/sbin/nologin megacorp 2>/dev/null || true

# systemd unit
cat > /etc/systemd/system/megacorp-debug.service << 'SVCEOF'
[Unit]
Description=MegaCorp Internal Debug Console
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/megacorp/debug_console.py
User=megacorp
Group=megacorp
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable megacorp-debug.service
systemctl start megacorp-debug.service

echo "[+] Flag 2 configured."

###############################################################################
# FLAG 3 - Port Knocking + SSH on Alternate Port
# FLAG{p0rt_kn0ck_s3cr3t_d00r}
###############################################################################
echo "[*] Configuring Flag 3 - Port Knocking + SSH..."

# Create the backdoor user
useradd -m -s /bin/bash backdoor 2>/dev/null || true
echo "backdoor:kn0ck_kn0ck" | chpasswd

cat > /home/backdoor/flag.txt << 'FLAG3EOF'
=============================================
  CONGRATULATIONS!
=============================================

You successfully:
  1. Discovered the port knocking hint
  2. Executed the correct knock sequence
  3. Connected to the hidden SSH service

FLAG{p0rt_kn0ck_s3cr3t_d00r}

=============================================
FLAG3EOF

chown backdoor:backdoor /home/backdoor/flag.txt
chmod 400 /home/backdoor/flag.txt

# ---------- SSH configuration ----------------------------------------------
# Primary SSH on port 22: key-only, root only (decoy - attacker cannot access)
# Secondary SSH on port 2222: password auth for backdoor user (behind knockd)

cat > /etc/ssh/sshd_config << 'SSHDEOF'
# MegaCorp SSH Configuration

# Primary listener - key auth only (decoy)
Port 22

# Secondary listener - behind port knocking
Port 2222

# Global settings
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Override: allow password auth ONLY on port 2222 for the backdoor user
Match LocalPort 2222 User backdoor
    PasswordAuthentication yes
SSHDEOF

systemctl enable ssh
systemctl restart ssh

# ---------- iptables rules -------------------------------------------------
# Flush existing rules (start clean)
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD

# Default policies: allow everything except port 2222
# We keep a permissive baseline so the CTF stays playable;
# only port 2222 is blocked until knockd opens it.
iptables -A INPUT -p tcp --dport 2222 -j DROP

# ---------- knockd configuration -------------------------------------------
cat > /etc/knockd.conf << 'KNOCKEOF'
[options]
    UseSyslog

[openSSH]
    sequence    = 7000,8000,9000
    seq_timeout = 15
    command     = /usr/sbin/iptables -I INPUT 1 -s %IP% -p tcp --dport 2222 -j ACCEPT
    tcpflags    = syn

[closeSSH]
    sequence    = 9000,8000,7000
    seq_timeout = 15
    command     = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 2222 -j ACCEPT
    tcpflags    = syn
KNOCKEOF

# knockd interface: HARDCODED, never auto-detected. See lxc-gotchas.md #3.
#
# `ip -o link show` reports LXC veth interfaces as "eth0@if<N>" (e.g. eth0@if96,
# where N changes on every container recreate). knockd passes that string
# straight to pcap and dies with "could not open eth0@if96: No such device
# exists". The old auto-detect here fell back to "eth0" only when the result was
# EMPTY, which it never is — so the fallback was dead code and knockd failed on
# every single deploy, taking the port-knocking flag with it.
PRIMARY_IFACE="eth0"

# Configure knockd defaults to start on the right interface
cat > /etc/default/knockd << KNOCKDEFEOF
# knockd defaults
START_KNOCKD=1
KNOCKD_OPTS="-i ${PRIMARY_IFACE}"
KNOCKDEFEOF

systemctl enable knockd
systemctl restart knockd

# Verification (lxc-gotchas.md #10): a silently dead knockd means the port
# knocking flag is unobtainable, and nothing else in this script would notice.
sleep 1
if systemctl is-active --quiet knockd; then
    echo "[OK] knockd is running on ${PRIMARY_IFACE}"
else
    echo "[FAIL] knockd did NOT start — port knocking flag will be unobtainable"
    systemctl status knockd --no-pager -l 2>&1 | tail -5
fi

# Auto-close port 2222 after 30 seconds via a helper timer
# We create a lightweight systemd path/timer that re-drops port 2222
# but since knockd itself does not have a native timeout, we add an
# iptables rule with the "recent" module or a cron-like approach.
# Simplest reliable method: modify the knockd open command to schedule
# automatic closure after 30 seconds.

# Rewrite knockd.conf with a self-closing open rule
cat > /etc/knockd.conf << KNOCKEOF2
[options]
    UseSyslog

[openSSH]
    sequence    = 7000,8000,9000
    seq_timeout = 15
    command     = /usr/sbin/iptables -I INPUT 1 -s %IP% -p tcp --dport 2222 -j ACCEPT && sleep 30 && /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 2222 -j ACCEPT &
    tcpflags    = syn

[closeSSH]
    sequence    = 9000,8000,7000
    seq_timeout = 15
    command     = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 2222 -j ACCEPT
    tcpflags    = syn
KNOCKEOF2

systemctl restart knockd

echo "[+] Flag 3 configured."

###############################################################################
# MOTD Banner
###############################################################################
echo "[*] Setting MOTD banner..."

cat > /etc/motd << 'MOTDEOF'

=============================================
   MegaCorp Production Server
   Authorized Access Only
=============================================
  All activity is monitored and logged.
  Unauthorized access will be prosecuted.
=============================================

MOTDEOF

# Also set the SSH banner
cat > /etc/issue.net << 'ISSUEEOF'
=============================================
 MegaCorp Production Server
 Authorized Access Only
=============================================
ISSUEEOF

# Ensure SSH uses the banner
if ! grep -q "^Banner" /etc/ssh/sshd_config; then
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    systemctl restart ssh
fi

###############################################################################
# Flag summary for root
###############################################################################
echo "[*] Writing flag summary..."

cat > /root/flags.txt << 'FLAGSEOF'
=============================================
  CTF Challenge: Network Recon
  Flag Summary (ADMIN ONLY)
=============================================

Flag 1 (Easy) - FTP Anonymous Access:
  Location : /srv/ftp/pub/.hidden/credentials.txt
  Value    : FLAG{4n0nym0us_ftp_l00t}
  Method   : Connect to FTP anonymously, explore hidden directories

Flag 2 (Medium) - Custom Service on Port 31337:
  Location : Returned by debug console service
  Value    : FLAG{h1dd3n_p0rt_s3rv1c3}
  Method   : Port scan -> find 31337 -> connect -> extract auth token
             from backup_old.tar.gz on FTP -> "debug MEGACORP-2024"

Flag 3 (Hard) - Port Knocking + SSH:
  Location : /home/backdoor/flag.txt
  Value    : FLAG{p0rt_kn0ck_s3cr3t_d00r}
  Method   : Read notes.txt hint on FTP -> knock 7000,8000,9000 ->
             SSH to port 2222 as backdoor:kn0ck_kn0ck -> read flag

=============================================
  Attack Chain:
  1. nmap scan discovers FTP (21), SSH (22), and port 31337
  2. FTP anonymous -> readme.txt, notes.txt, backup_old.tar.gz
  3. Hidden dir .hidden/ -> credentials.txt -> Flag 1
  4. Extract backup_old.tar.gz -> find auth token MEGACORP-2024
  5. nc <ip> 31337 -> "debug MEGACORP-2024" -> Flag 2
  6. notes.txt hints at knock sequence 7-8-9 (thousands)
  7. knock <ip> 7000 8000 9000 -> SSH port 2222 opens for 30s
  8. ssh backdoor@<ip> -p 2222 (pass: kn0ck_kn0ck) -> Flag 3
=============================================
FLAGSEOF

chmod 600 /root/flags.txt

###############################################################################
# Final service verification
###############################################################################
echo ""
echo "=============================================="
echo " Verifying services..."
echo "=============================================="

FAIL=0

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "${svc}"; then
        echo "  [OK] ${svc} is running"
    else
        echo "  [!!] ${svc} FAILED to start"
        FAIL=1
    fi
}

check_service vsftpd
check_service megacorp-debug
check_service knockd
check_service ssh

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "=============================================="
    echo " Setup complete! All services running."
    echo "=============================================="
else
    echo "=============================================="
    echo " Setup complete with WARNINGS. Check failed"
    echo " services above."
    echo "=============================================="
fi

echo ""
echo " Flags saved to /root/flags.txt"
echo " Run 'cat /root/flags.txt' for the full solution guide."
echo ""
