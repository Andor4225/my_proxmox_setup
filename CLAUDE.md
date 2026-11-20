# Proxmox Pentest Lab

> Current state overview. For dated event history, see [CHANGELOG.md](CHANGELOG.md). For subsystem deep-dives, see the docs map below.

## Subsystem Documentation Map

Deep architecture/operational detail lives in topic-specific files. **Read the relevant doc before working on that subsystem:**

| Subsystem | Doc | When to read |
|---|---|---|
| FAE practice labs | `fae/README.md` + `fae/design-spec.md` | Working on the troubleshooting labs (CT 201-207), their faults, or the deployer |
| CTF lab (LIVE, CT 211-215) | `ctf-lab.md` | Working on or redeploying the CTF challenge set |
| LXC setup gotchas | `lxc-gotchas.md` | Writing or editing any LXC setup script (10 known traps) |
| DFW AgentOps (website + VM templates) | _(kept in local tree, not committed)_ | Touching CT 300, dfwagentops.com deploy pipeline, or templates 900/901 |
| Windows backups | `windows-backup.md` + `plans/windows-backup-runbook.md` | Touching Samba shares or backup infrastructure |

## Server
- **Proxmox VE 9.2.32** (running kernel `7.0.14-30-pve`, fallbacks `7.0.14-28-pve`, `7.0.14-3-pve` and `6.17.13-21-pve`; updated 2026-11-20) at `192.168.10.147:8006`
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
- **Token**: `root@pam!claude-mcp` — **privsep ON** (2026-07-04); scoped to custom role `ClaudeMCP` at `/` = 6 privs only: `VM.Audit VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback Sys.Audit Datastore.Audit`. No longer root-equivalent. Covers the 14 REST-API tools; the 4 SSH-based tools (`exec_command`, `list_docker`, `docker_manage`, `docker_run`) use root SSH and bypass this token entirely (tracked as M3b). Renewed by Gavin; expires **2027-12-31**.
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

### VM 110 — omarchy (QEMU)
Omarchy 4.0.0 (Arch/Hyprland desktop) try-out VM, created 2026-08-22. UEFI (OVMF, no pre-enrolled SB keys), q35, `cpu host`, 2 cores, 8GB RAM, 64GB disk + 4M EFI on **sata-vmstorage**, virtio-gpu, virtio net on vmbr0. ISO `local:iso/omarchy-4.0.0.iso`. Access the installer via the Proxmox web console (noVNC). ⚠️ No GPU passthrough (host has only Intel iGPU), so Hyprland runs on virtio-gpu software rendering (llvmpipe) and may be sluggish. Excluded from the vzdump backup job (disposable). Boot order `scsi0;ide2` auto-boots the disk once installed.

### FAE Practice Labs (CTIDs 201–207)
4 troubleshooting labs for hands-on Linux/networking practice: **lab1** broken router (CT 201/202), **lab2** OpenVPN tunnel failure (CT 203/204), **lab3** raw log playground (CT 205), **lab4** name resolution (CT 206 `lab-dns-a` + CT 207 `lab-dns-b`). Each container is **dual-homed**: `eth0` mgmt on `vmbr0` (`192.168.10.201-207`, Tailscale-reachable, never touched by faults) + `eth1` on an **isolated** bridge (`vmbr1`/`vmbr2`/`vmbr3`, no uplink) where all breakage lives. Deliberately broken; re-arm via snapshot rollback. See `fae/README.md`.

### CTF Lab (CTIDs 211–215) — **REDEPLOYED 2026-07-28**
5 Debian 12 containers, 13 flags / 2500 points: web exploitation (211), Linux privesc (212), crypto & forensics (213), network recon (214), scoreboard (215). Static IPs `192.168.10.211-215`.

Rebuilt on **211–215** rather than its original 201–205, which the FAE labs now hold. Containers are **unprivileged with no nesting** (they are deliberately vulnerable and Kali-reachable; a privileged LXC would turn an intended container-root privesc into PVE host root, and this host also runs CT 300 production). `deploy.sh` whitelists only its own five CTIDs and carries an explicit deny list for 100/201-207/300/900/901.

Kali (UniFi `Isol-Net`, VLAN 77) has no LAN path to the CTF by design; see Network / Kali access. Tailscale access needs no change. Deploy: `bash /root/ctf/deploy.sh deploy all`. See `ctf-lab.md`.

### DFW AgentOps
- **Website** — CT 300 at `192.168.10.220` serves `https://dfwagentops.com` via Cloudflare Tunnel
- **VM templates** — 900 (`staging-openclaw-template`) and 901 (`managed-openclaw-template`) for client deployments
- Full deploy pipeline, nginx config, template details, and management scripts are documented in the local tree (`dfwagentops.md`), which is not committed to this repo
- **Other guests (unprivileged, onboot, `sata-vmstorage`)** — CT 240 `client-nikkisbarberlounge` (`192.168.10.240`, 2 cores / 3GB, 24G disk; a DFW AgentOps client deployment); CT 241 `ollama-shared` (`192.168.10.241`, 3 cores / 8GB, 12G disk, 76% used)

### Windows Backups
SMB-over-Tailscale shares from `\\100.81.116.89\` (`backup-files` = restic, `backup-images` = Veeam) to `gavin:gavin`-owned dirs on the OWC Express 4M2 enclosure. nftables locks ports 139/445 to `lo` + `tailscale0` only. Windows restic runs **hourly at :03** (median 1.8 min, max 63.7 min); Veeam nightly 04:30. See `windows-backup.md` for architecture and `plans/windows-backup-runbook.md` for operations.

**Veeam capacity reset (2026-09-02):** `backup-images` had filled to 94% — a forever-forward image of the whole 321 GB C: volume doesn't fit a 469 GB disk. Fixed by trimming Windows C: ~60 GB (moved Ollama/PlatformIO/Arduino data to D: via env vars, cleared caches, Steam → D:), reconfiguring Veeam to **volume-level C:-only** with **3-day retention**, and deleting the bloated old chain so a fresh lean full (~190 GB) could be taken. Ongoing rule: keep Veeam lean (it's the bare-metal image; restic is the primary *data* backup) — reproducible bulk stays off C:, and D: is excluded from the Veeam image. See CHANGELOG 2026-09-02.

**Second crunch (2026-11-01):** "Defragment and compact full backup file" had been re-enabled. It needs about one full's size free (~272 GB), so on this 469 GB target it can never succeed, and it caused nightly Warnings. It is now **OFF and must stay off**. C: was trimmed 385 → 300 GiB (an 80 GB Dropbox cache), the chain was reset again, and the new chain lives in `Window-Backup_2`. The Windows heartbeat (`utilities\restic\backup-heartbeat.ps1`) was rewritten: job filter, cause in alerts, signature-based re-alerting, fail-closed sanitizer. See CHANGELOG 2026-11-01.

## Automated Maintenance

Two systemd timers run unattended maintenance on the host. Both write to plain log files AND systemd journal so OpenClaw and humans can both consume them.

| Service | Cadence | What it does |
|---|---|---|
| `backup-health-check.timer` | daily ~09:00 (RandomizedDelaySec=300) | Verifies OWC mounts, free space, restic + Veeam freshness, USB errors, and (check 6) whether auto-updates still succeed (WARNs on a missing/stale >20d/bad success marker or a failed updater unit) and whether the post-update guest restore finished (WARNs if the restore list outlives 60 min, or is future-dated). Exit 0/1/2 consumed by OpenClaw → Discord on non-zero. |
| `proxmox-monthly-update.timer` | 6th & 20th of every month, 02:30 + RandomizedDelaySec=600 (semi-monthly; changed 2026-07-04 from bi-monthly to cut patch latency) | Pre-flight (free space + backup-health-check run with `BHC_SKIP_UPDATER_CHECK=1` + flock on `/var/run/vzdump.lock` + pvesh tasks + **backup-activity gate**) → snapshot all CTs/VMs as `auto_update_YYYY_MM_DD_HHMMSS` (was month-only until 2026-11-20: the 2nd run of a month collided) → `apt full-upgrade -y --force-confold --force-confdef` → reboot only if running kernel ≠ latest installed (first records the running guests + `boot_id` to `/var/lib/proxmox-monthly-update/restore-guests`, merging any unresolved list; fatal with no reboot if that fails; **`proxmox-guest-restore.service`** then restarts them after boot, re-checks all, and archives the list to `.done` only if every one runs) → prune snapshots older than 60 days (only on no-reboot runs). The gate (`check_backup_quiet`, run in pre-flight **and again right before apt**) requires both backup paths to be mounted ext4, then defers only on a file open over SMB (`smbstatus -L --json`, fails closed) or any write under `/mnt/backup-files` / `/mnt/backup-images` in the last 15 min; an idle SMB session no longer blocks (it did, and aborted every run 2026-09-06 to 11-06). Success stamps `/var/lib/proxmox-monthly-update/last-success`. The 02:30 slot is quiet (restic ends by ~02:09). Last run 2026-11-20 (manual rerun after the 02:38 timer run aborted on a snapshot-name collision; kernel reboot + first real guest restore, 16/16). The unit is still named `proxmox-monthly-update.*` (misnomer — twice-monthly). |

A **`vzdump` backup job** (pvescheduler, not a systemd timer; added 2026-08-14) also runs unattended: **guests 100/300/900/901 → `sata-backups`**, `mode=snapshot`, `compress=zstd`, **`sun 05:30`**, retention `keep-last=4`. These are the non-reproducible guests (CT 300 production site, VM 100, templates 900/901) — the CTF/FAE labs are excluded since they rebuild from the deploy scripts. `/etc/vzdump.conf` is tuned `zstd: 1` + `bwlimit: 80000` to stay gentle on the 2-core CPU (a full run still briefly hits ~90°C — benign, never throttles). Manage with `pvesh get/set /cluster/backup` or the web UI (Datacenter → Backup). ⚠️ This is the guests' **only real backup** — snapshots (`auto_update_*`) share the guest's disk and don't survive a pool loss.

Script sources live in `scripts/`, unit files in `systemd/`, both deployed to `/usr/local/sbin/` and `/etc/systemd/system/` on the host. Run on demand:
- `/usr/local/sbin/backup-health-check.sh` (or `systemctl start backup-health-check.service`)
- `/usr/local/sbin/proxmox-monthly-update.sh --dry-run` (no changes, just pre-flight + apt update preview)
- `/usr/local/sbin/proxmox-monthly-update.sh` (full live run — same as the timer)

Disable a timer: `systemctl disable --now <name>.timer`. Re-enable: `systemctl enable --now <name>.timer`. Logs at `/var/log/{backup-health-check,proxmox-monthly-update}.log` and via `journalctl -u <unit>`.

## Network / Kali access

Kali sits on UniFi network **`Isol-Net`, VLAN 77** (`192.168.77.0/24`, network isolation ON); the lab is on **`Trusted`, VLAN 10** (`192.168.10.0/24`). Gateway `192.168.1.1`, UniFi Network 10.6, legacy (rule-based) firewall.
- **Kali has NO LAN path to the labs, by Gavin's choice (2026-11-10).** `LAN_IN` #20016 `Isol - Block RFC1918` drops Isol-Net → all private IPs, and Isol-Net's **Network Isolation** setting blocks inter-VLAN traffic regardless of custom rules.
- **What was tried:** an accept rule (#20011, Isol-Net → group `Kali Lab Targets`, above #20016) still saw 0 packets reach `vmbr0`, so isolation wins over custom rules. Gavin kept isolation ON and has deleted that rule (confirmed 2026-11-19). The `Kali Lab Targets` address group (formerly the unused `CTF Lab`) may remain.
- **To open access later:** isolation must go OFF, with an explicit `LAN_IN` drop of NEW connections into Isol-Net replacing it. That needs Gavin's decision. Never broaden Isol-Net → VLAN 10.

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
│   ├── proxmox-monthly-update.sh # Semi-monthly automated apt full-upgrade
│   ├── proxmox-guest-restore.sh  # Post-update-reboot guest restore (run by its systemd unit)
│   └── tests/                    # test-update-gates.sh + test-guest-restore.sh: bash <test> <scripts-dir>, run on host
├── systemd/                      # systemd units (deployed to /etc/systemd/system/)
│   ├── proxmox-monthly-update.service
│   ├── proxmox-monthly-update.timer
│   └── proxmox-guest-restore.service # oneshot at boot, After=pve-guests; enabled
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
│   ├── lab3-log-playground/      # setup.sh, gen-syslog.sh
│   └── lab4-name-resolution/     # setup.sh, break.sh, FIELD_TICKET.txt
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
- **Windows**: `andor4225` / `100.101.161.87`. `accept-routes` has been **off** since 2026-11-01, so LAN traffic goes out Ethernet and not through pve's subnet route. When it was on, pve dropping off Tailscale black-holed the whole LAN from Windows. Keep it off on home-LAN machines (CHANGELOG 2026-11-01).
- **Ubuntu travel**: `ubuntu-g7` / `100.87.250.125`
- **Kali VM**: Not yet on Tailscale — works if VM uses NAT networking through Ubuntu host, otherwise needs its own Tailscale install
- **Remote CTF access**: From any Tailscale device, CTF containers are reachable at their LAN IPs (`192.168.10.211-215`) via the subnet route
- **Remote SSH**: `ssh root@proxmox-pve` or `ssh root@100.81.116.89` — OpenSSH over Tailscale. To add a new device: append its public key to `/root/.ssh/authorized_keys` on Proxmox

## User Context
- Intermediate pentester practicing on home lab
- Uses Kali Linux as attack machine
- Travels often — accesses lab remotely via Tailscale from Ubuntu laptop + Kali VM
- All work is authorized security testing on owned infrastructure

