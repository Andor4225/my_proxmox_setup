# Proxmox Pentest Lab

> Current state overview. For dated event history, see [CHANGELOG.md](CHANGELOG.md). For subsystem deep-dives, see the docs map below.

## Subsystem Documentation Map

Deep architecture/operational detail lives in topic-specific files. **Read the relevant doc before working on that subsystem:**

| Subsystem | Doc | When to read |
|---|---|---|
| FAE practice labs | `fae/README.md` + `fae/design-spec.md` | Working on the troubleshooting labs (CT 201-205), their faults, or the deployer |
| CTF lab (decommissioned) | `ctf-lab.md` | Rebuilding the retired CTF challenge set |
| LXC setup gotchas | `lxc-gotchas.md` | Writing or editing any LXC setup script (10 known traps) |
| DFW AgentOps (website + VM templates) | _(kept in local tree, not committed)_ | Touching CT 300, dfwagentops.com deploy pipeline, or templates 900/901 |
| Windows backups | `windows-backup.md` + `plans/windows-backup-runbook.md` | Touching Samba shares or backup infrastructure |

## Server
- **Proxmox VE 9.2.3** (kernel `7.0.6-2-pve`, fallback `6.17.13-11-pve`) at `192.168.10.147:8006`
- **Node name**: `pve`
- **Model**: HP Laptop 15-dw3xxx
- **CPU**: Intel i3-1115G4 @ 3.00GHz (2 cores / 4 threads, boost 4.1GHz, 28W TDP)
- **RAM**: 32GB
- **GPU**: Intel UHD Graphics G4 (integrated)
- **Storage**:
  - Intel NVMe 477GB (boot) — `pve-root` 96GB ext4 (`local`) + `pve-data` LVM-thin ~349GB (`local-lvm`)
  - Intel NVMe 27.3GB (Optane H10 cache half) — ext4 LABEL=`scratch` → `/mnt/scratch` → Proxmox `scratch` storage (ISOs/snippets, fast tier). Throws periodic correctable PCIe errors (`10000:e2:00.0`); `nofail` in fstab.
  - WD Blue SATA SSD 932GB:
    - sda1 200GB ext4 → `/mnt/pve-backups` → Proxmox `sata-backups` storage (Proxmox vzdump/templates)
    - sda2 731GB LVM-thin → `sata-vmstorage` (VM/CT disks)
  - **OWC Express 4M2** — external 4-bay NVMe enclosure, USB-C 3.2 Gen 2 (USB ID `1e91:de83`). Stress-test verified 2026-05-22 (30GB write-verify, 0 bridge resets). Holds the 3 NVMe sticks; 4th bay free:
    - sdb 256GB ext4 LABEL=`fast-tier` → `/mnt/fast-tier` (local Proxmox use)
    - sdc 500GB ext4 LABEL=`backup-files` → `/mnt/backup-files` (Windows restic repo at `restic/` subdir)
    - sdd 512GB ext4 LABEL=`backup-images` → `/mnt/backup-images` (Windows Veeam images)
    - All three: `x-systemd.automount,nofail` in fstab (self-heal after reboot/replug)
- **Monitoring**: lm-sensors, smartmontools, htop, iotop
- **Security**: fail2ban (sshd + Proxmox web UI jails, 3 attempts / 3hr ban); web UI TOTP 2FA enabled for `root@pam` (+ recovery keys, 2026-07-04); SPICE console proxy (`spiceproxy`, port 3128) disabled 2026-07-04 (unused; noVNC via 8006 unaffected). See [CHANGELOG.md](CHANGELOG.md) 2026-07-04 for the pentest + hardening pass.
- **Utilities**: tmux, iperf3, net-tools, ethtool
- **Network**: `vmbr0` bridge, static IP `192.168.10.147/24`, subnet `192.168.10.0/24`
- **NIC**: Realtek RTL8111 Gigabit Ethernet + RTL8821CE 802.11ac WiFi
- **SSH**: OpenSSH key-based auth only (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`, `AllowUsers root`). MACs restricted to strong ETM set via `/etc/ssh/sshd_config.d/10-hardening.conf` (2026-07-04). Keys installed for:
  - Windows machine (this project's MCP server)
  - OpenClaw container on Pi (`openclaw-container@pi`)
  - Pi host (`andor4225@GsRaspberryPi`)
  - Ubuntu travel laptop (`dick-turpin@Ubuntu-G7`)
  - Kali VM (`kali@kali`, ed25519, added 2026-07-28)
- **Tailscale**: v1.96.4, hostname `proxmox-pve`, IP `100.81.116.89`
  - Subnet router advertising `192.168.10.0/24` (approved)
  - **Tailscale SSH is disabled** — all SSH goes through OpenSSH for reliable cron auth
  - IP forwarding enabled (`/etc/sysctl.d/99-tailscale.conf`)
  - UDP GRO optimized (`/etc/networkd-dispatcher/routable.d/50-tailscale-gro`)

## API Access
- **Token**: `root@pam!claude-mcp` — **privsep ON** (2026-07-04); scoped to custom role `ClaudeMCP` at `/` = 6 privs only: `VM.Audit VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback Sys.Audit Datastore.Audit`. No longer root-equivalent. Covers the 14 REST-API tools; the 4 SSH-based tools (`exec_command`, `list_docker`, `docker_manage`, `docker_run`) use root SSH and bypass this token entirely (tracked as M3b). Expire ~2026-10-16.
- **Secret**: stored in `.env` (gitignored), ACL locked to `Gavin`+`SYSTEM` only. Rotating requires `pveum user token remove`+`add` (mints a new secret) then update `.env` → restart MCP session.
- **SSL**: self-signed cert — requires `NODE_TLS_REJECT_UNAUTHORIZED=0`

## MCP Server
- TypeScript MCP server at `src/index.ts` wrapping Proxmox REST API + SSH
- Configured in `.mcp.json` for this project
- **18 tools**: list_vms, list_containers, get_status, get_vm_config, start, stop, shutdown, create_snapshot, list_snapshots, rollback_snapshot, list_storage, list_networks, cluster_resources, exec_command, list_docker, docker_manage, docker_run, list_tasks
- Build: `npm run build` → `dist/index.js`
- Requires session restart to load MCP tools

## Existing VMs/Containers

### VM 100 — ubuntu-target (QEMU)
Pre-existing Ubuntu VM with OWASP Juice Shop in Docker. 2 vCPUs, 4GB RAM, 32GB disk. User's original pentest target.

### FAE Practice Labs (CTIDs 201–205)
3 troubleshooting labs for hands-on Linux/networking practice: **lab1** broken router (CT 201/202), **lab2** OpenVPN tunnel failure (CT 203/204), **lab3** raw log playground (CT 205). Each container is **dual-homed**: `eth0` mgmt on `vmbr0` (`192.168.10.201-205`, Tailscale-reachable, never touched by faults) + `eth1` on an **isolated** bridge (`vmbr1`/`vmbr2`, no uplink) where all breakage lives. Deliberately broken; re-arm via snapshot rollback. See `fae/README.md`.

### CTF Lab (CTIDs 211–215) — **REDEPLOYED 2026-07-28**
5 Debian 12 containers, 13 flags / 2500 points: web exploitation (211), Linux privesc (212), crypto & forensics (213), network recon (214), scoreboard (215). Static IPs `192.168.10.211-215`.

Rebuilt on **211–215** rather than its original 201–205, which the FAE labs now hold. Containers are **unprivileged with no nesting** (they are deliberately vulnerable and Kali-reachable; a privileged LXC would turn an intended container-root privesc into PVE host root, and this host also runs CT 300 production). `deploy.sh` whitelists only its own five CTIDs and carries an explicit deny list for 100/201-207/300/900/901.

⚠️ The UniFi VLAN70→VLAN10 whitelist for Kali still covers `.201-.205` and **must be widened to `.211-.215`**. Tailscale access needs no change. Deploy: `bash /root/ctf/deploy.sh deploy all`. See `ctf-lab.md`.

### DFW AgentOps
- **Website** — CT 300 at `192.168.10.220` serves `https://dfwagentops.com` via Cloudflare Tunnel
- **VM templates** — 900 (`staging-openclaw-template`) and 901 (`managed-openclaw-template`) for client deployments
- Full deploy pipeline, nginx config, template details, and management scripts are documented in the local tree (`dfwagentops.md`), which is not committed to this repo

### Windows Backups
SMB-over-Tailscale shares from `\\100.81.116.89\` (`backup-files` = restic, `backup-images` = Veeam) to `gavin:gavin`-owned dirs on the OWC Express 4M2 enclosure. nftables locks ports 139/445 to `lo` + `tailscale0` only. See `windows-backup.md` for architecture and `plans/windows-backup-runbook.md` for operations.

## Automated Maintenance

Two systemd timers run unattended maintenance on the host. Both write to plain log files AND systemd journal so OpenClaw and humans can both consume them.

| Service | Cadence | What it does |
|---|---|---|
| `backup-health-check.timer` | daily ~09:00 (RandomizedDelaySec=300) | Verifies OWC mounts, free space, restic + Veeam freshness, USB errors. Exit 0/1/2 consumed by OpenClaw → Discord on non-zero. |
| `proxmox-monthly-update.timer` | 6th & 20th of every month, 02:30 + RandomizedDelaySec=600 (semi-monthly; changed 2026-07-04 from bi-monthly to cut patch latency) | Pre-flight (free space + backup-health-check + flock on `/var/run/vzdump.lock` + smbstatus + pvesh tasks) → snapshot all CTs/VMs as `auto_update_YYYY_MM` → `apt full-upgrade -y --force-confold --force-confdef` → reboot only if running kernel ≠ latest installed → prune snapshots older than 60 days. Next fire: **Mon 2026-07-06 02:36 CDT**. Note: the unit is still named `proxmox-monthly-update.*` (now a mild misnomer — cadence is twice-monthly). |

A **`vzdump` backup job** (pvescheduler, not a systemd timer; added 2026-08-14) also runs unattended: **guests 100/300/900/901 → `sata-backups`**, `mode=snapshot`, `compress=zstd`, **`sun 05:30`**, retention `keep-last=4`. These are the non-reproducible guests (CT 300 production site, VM 100, templates 900/901) — the CTF/FAE labs are excluded since they rebuild from the deploy scripts. `/etc/vzdump.conf` is tuned `zstd: 1` + `bwlimit: 80000` to stay gentle on the 2-core CPU (a full run still briefly hits ~90°C — benign, never throttles). Manage with `pvesh get/set /cluster/backup` or the web UI (Datacenter → Backup). ⚠️ This is the guests' **only real backup** — snapshots (`auto_update_*`) share the guest's disk and don't survive a pool loss.

Script sources live in `scripts/`, unit files in `systemd/`, both deployed to `/usr/local/sbin/` and `/etc/systemd/system/` on the host. Run on demand:
- `/usr/local/sbin/backup-health-check.sh` (or `systemctl start backup-health-check.service`)
- `/usr/local/sbin/proxmox-monthly-update.sh --dry-run` (no changes, just pre-flight + apt update preview)
- `/usr/local/sbin/proxmox-monthly-update.sh` (full live run — same as the timer)

Disable a timer: `systemctl disable --now <name>.timer`. Re-enable: `systemctl enable --now <name>.timer`. Logs at `/var/log/{backup-health-check,proxmox-monthly-update}.log` and via `journalctl -u <unit>`.

## Network / Kali access

The Kali machine is on **VLAN 70** (subnet `192.168.77.0/24`); Proxmox lab is on **VLAN 10** (`192.168.10.0/24`). Kali can reach the CTF containers and Proxmox/web server via a UniFi Dream Machine firewall rule that whitelists:
- `192.168.10.201-205` (CTF)
- `192.168.10.147` (Proxmox host)
- `192.168.10.220` (web server)

Rest of the LAN remains isolated from Kali. This preserves security segmentation while allowing authorized lab work. Do NOT broaden this rule to allow all VLAN70→VLAN10 traffic.

## Planned (Not Yet Built)
- Small AD lab: 1 DC + 1 workstation (user needs to provide Windows Server ISO)
- Vulnerable REST API container
- Network pivoting multi-subnet lab
- Custom vulnerable web apps beyond the CTF challenges
- Plausible Analytics CE for dfwagentops.com (plan saved at `plans/plausible-analytics-setup.md`, implement after site launch has real traffic)

## Project Structure
```
proxmox/                          # This repo (on Windows dev machine)
├── CLAUDE.md                     # Current-state overview (this file)
├── CHANGELOG.md                  # Dated event log
├── ctf-lab.md                    # CTF containers, deploy commands, creds
├── lxc-gotchas.md                # LXC setup script lessons-learned (10 traps)
├── windows-backup.md             # Samba/Tailscale backup architecture
├── .env                          # API token (gitignored)
├── .gitignore
├── .mcp.json                     # MCP server config for Claude Code
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts                  # MCP server entry point (SSH exec timeout: 120s)
│   └── proxmox-client.ts         # Proxmox REST API client
├── dist/                         # Compiled JS (gitignored)
├── scripts/                      # Standalone scripts (deployed to host /usr/local/sbin/)
│   ├── owc-stress-test.sh        # Enclosure write-verify validation tool
│   ├── backup-health-check.sh    # Daily backup health check
│   └── proxmox-monthly-update.sh # Bi-monthly automated apt full-upgrade
├── systemd/                      # systemd units (deployed to /etc/systemd/system/)
│   ├── proxmox-monthly-update.service
│   └── proxmox-monthly-update.timer
├── plans/                        # Saved implementation plans + runbooks
│   └── windows-backup-runbook.md # (verified 2026-07-20 — the only file here)
├── fae/                          # FAE practice labs (deployed to host /root/fae/)
│   ├── README.md                 # Teaching guide: access, methodology, per-lab walkthrough
│   ├── SOLUTIONS.md              # Spoilers — deliberately separate from README
│   ├── design-spec.md            # Approved design: topology, faults, risks
│   ├── deploy.sh                 # deploy|break|reset|keys|status|destroy
│   ├── lib/common.sh             # Host-side helpers + CTID/mgmt-path guards
│   ├── lab1-broken-router/       # setup.sh, break.sh, FIELD_TICKET.txt
│   ├── lab2-tunnel-failure/      # setup.sh, break.sh, FIELD_TICKET.txt
│   └── lab3-log-playground/      # setup.sh, gen-syslog.sh
└── ctf/                          # CTF lab, LIVE on CT 211-215 — see ctf-lab.md
    ├── deploy.sh                 # Master deployer script
    ├── challenges/
    │   ├── web-exploit/setup.sh
    │   ├── linux-privesc/setup.sh
    │   ├── crypto-forensics/setup.sh
    │   └── network-recon/setup.sh
    └── scoreboard/setup.sh
```

## External Monitoring — OpenClaw (Raspberry Pi)
- **OpenClaw** a.k.a Payload_Ghost is running on a Raspberry Pi on the same network
- Has SSH access to Proxmox (`root@192.168.10.147`) via both container and host keys
- Proxmox health check runs ~3×/day: CPU/NVMe temps, load, RAM, disk, LVM-thin, container/VM status, backup health
- Reports to user via Discord
- Alerts immediately on critical thresholds (CPU >85C, NVMe >75C, RAM <4GB, disk >85%, containers down)

## Remote Access — Tailscale
- **Tailnet**: All machines on the same Tailscale account
- **Proxmox**: `proxmox-pve` / `100.81.116.89` — subnet router for `192.168.10.0/24`
- **Pi**: `gsraspberrypi` / `100.108.179.114`
- **Windows**: `andor4225` / `100.101.161.87`
- **Ubuntu travel**: `ubuntu-g7` / `100.87.250.125`
- **Kali VM**: Not yet on Tailscale — works if VM uses NAT networking through Ubuntu host, otherwise needs its own Tailscale install
- **Remote CTF access**: From any Tailscale device, CTF containers are reachable at their LAN IPs (`192.168.10.201-205`) via the subnet route
- **Remote SSH**: `ssh root@proxmox-pve` or `ssh root@100.81.116.89` — OpenSSH over Tailscale. To add a new device: append its public key to `/root/.ssh/authorized_keys` on Proxmox

## User Context
- Intermediate pentester practicing on home lab
- Uses Kali Linux as attack machine
- Travels often — accesses lab remotely via Tailscale from Ubuntu laptop + Kali VM
- All work is authorized security testing on owned infrastructure

