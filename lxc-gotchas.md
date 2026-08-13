# LXC CTF Gotchas — Lessons Learned

Recurring issues hit during LXC container setup work in this lab. **Apply these fixes in all future setup.sh scripts.** Read this file before writing or editing any LXC setup script.

---

### 1. Nginx: Always remove the default site
Debian's nginx ships with a `default` symlink in `/etc/nginx/sites-enabled/` that serves the "Welcome to nginx!" page. If your CTF app has its own site config, the default will still win on port 80.
```bash
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
```
**Always include this in setup scripts that use nginx.**

### 2. SSH: systemd socket activation overrides sshd_config ports
Debian 12 uses `ssh.socket` (systemd socket activation) which **ignores the `Port` directive in sshd_config**. The socket unit only listens on port 22 by default. If your challenge needs SSH on a non-standard port (e.g., 2222):
```bash
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/override.conf << 'EOF'
[Socket]
ListenStream=
ListenStream=22
ListenStream=2222
EOF
systemctl daemon-reload
systemctl restart ssh.socket
systemctl restart ssh
```
The empty `ListenStream=` clears the inherited value before adding both ports.
**Always check for socket activation when configuring non-standard SSH ports.**

### 3. knockd: Interface naming in LXC containers
LXC containers show interfaces as `eth0@if<N>` (e.g., `eth0@if12`) in `ip link` output. knockd's default config may pick up the full `eth0@if12` name and fail with "No such device exists". The correct interface name is just `eth0`.
```bash
# In /etc/default/knockd or the systemd unit:
KNOCKD_OPTS="-i eth0"
```
**Always hardcode `-i eth0` for knockd in LXC containers. Never auto-detect the interface name.**

### 4. Proxmox API tokens: Disable privilege separation
When creating API tokens with `pvesh create .../token/name`, the default `privsep=1` restricts the token to only explicitly granted permissions (which is nothing for a new token). For full-access lab management:
```bash
pvesh create /access/users/root@pam/token/<name> -privsep 0
```
**Always pass `-privsep 0` when creating lab management tokens.**

### 5. LXC container setup: Wait for network before apt
Fresh LXC containers on DHCP need a moment to acquire an IP. Setup scripts that immediately run `apt update` may fail. The deploy.sh handles this, but if running setup scripts manually:
```bash
# Wait for network
for i in $(seq 1 15); do ping -c1 8.8.8.8 &>/dev/null && break; sleep 2; done
```

### 6. Locale warnings in LXC containers
Debian 12 LXC containers spam `perl: warning: Setting locale failed` on almost every apt/dpkg operation. This is cosmetic but noisy. Suppress by adding to setup scripts:
```bash
apt-get install -y locales > /dev/null 2>&1
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen > /dev/null 2>&1
export LC_ALL=en_US.UTF-8
```

### 7. Always install curl in utility containers
The Debian 12 minimal template does not include `curl`. Any container that needs HTTP testing or health checks (especially the scoreboard) should explicitly install it:
```bash
apt-get install -y curl
```

### 8. SUID binaries: Set the bit after compilation
When compiling a custom SUID binary with gcc, the SUID bit must be set as a **separate step** after `gcc` finishes. Don't rely on setup scripts completing all steps — verify the bit is set:
```bash
gcc -o /usr/local/bin/vuln_binary source.c
chmod u+s /usr/local/bin/vuln_binary
# Verify:
ls -la /usr/local/bin/vuln_binary  # should show -rwsr-xr-x
```

### 9. Cron jobs: Use /etc/crontab, not crontab -e
In LXC containers, `crontab -e` for root may not persist across service restarts. Write directly to `/etc/crontab` for reliability:
```bash
echo "*/2 * * * * root /opt/scripts/backup.sh" >> /etc/crontab
systemctl restart cron
```

### 10. Setup script verification
Every setup.sh should end with a verification block that checks all services, files, and permissions are correct. This caught multiple issues during the first deployment. Pattern:
```bash
echo "=== Verification ==="
systemctl is-active <service> && echo "[OK] service" || echo "[FAIL] service"
[ -f /path/to/flag ] && echo "[OK] flag exists" || echo "[FAIL] flag missing"
ls -la /path/to/suid | grep -q "^-rws" && echo "[OK] SUID set" || echo "[FAIL] SUID missing"
```

### 11. `chown` clears the setuid/setgid bit — always chmod LAST
`chown` strips setuid/setgid **even when ownership doesn't change** (`chown root:root` on a root-owned file still clears it). So `chmod 4755 X; chown root:root X` ships a non-SUID binary while the script looks successful. Order it `chown` first, `chmod` last, then verify functionally with `stat -c '%A'` matching `-rws*` (per #10). Hit on 2026-07-28 across three SUID binaries in the privesc challenge.

### 12. `set -euo pipefail` silently truncates setup scripts — three traps
LXC setup scripts run with `set -euo pipefail`, and a mid-run abort drops every later step (flag, service, decoy) with no error unless the deployer is fault-tolerant. Three recurring killers, all seen 2026-07-28:
- **`((var++))` returns exit 1 when var is 0** (post-increment yields the old value → arithmetic-false). Under `set -e` a `((PASS++))` in a verify loop aborts on the first PASS. Use `PASS=$((PASS + 1))`.
- **`(crontab -l | grep -v ...; echo ...) | crontab -`** dies when root has no crontab (`crontab -l` exits 1, `grep -v` exits 1 on empty) — the subshell dies before `echo` and pipefail propagates. Build a temp file with `|| true` guards instead.
- **Any bare `grep`/`crontab -l`/`id`/`getent`/pipeline** that returns non-zero on a normal "not found"/empty case. Wrap in `if`/`||`, never leave as a bare statement. General rule: in a `set -e` script, a command whose non-zero exit is *expected* must be in a conditional or suffixed `|| true`.
