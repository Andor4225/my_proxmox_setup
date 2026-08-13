# CTF Lab

> **Redeployed 2026-07-28 on CTIDs 211–215.** This lab was decommissioned on 2026-07-04 (its original CTIDs 201–205 were handed to the FAE practice labs) and rebuilt on 2026-07-28 on a new, non-conflicting range. Both labs now coexist.

5 Debian 12 LXC containers running a 13-flag CTF challenge set. Total: 2500 points (Easy=100, Medium=200, Hard=300).

> **For LXC setup script work, also read `lxc-gotchas.md`** — 10 known traps from this lab's first build.

## Containers

Static IPs configured via Proxmox `net0` (`gw=192.168.10.1`). These were **DHCP** before the 2026-07-28 rebuild, which contradicted the documented addresses and made the Kali firewall whitelist unreliable.

| CTID | Name | IP | Purpose | Access |
|------|------|----|---------|--------|
| 211 | ctf-web-exploit | 192.168.10.211 | SQLi, XSS, SSRF (3 flags) | Browser: http://IP |
| 212 | ctf-linux-privesc | 192.168.10.212 | SUID, cron, sudo, passwd (4 flags) | `ssh ctfplayer@IP` / `ctfplayer123` |
| 213 | ctf-crypto-forensics | 192.168.10.213 | Base64, stego, XOR log analysis (3 flags) | `ssh analyst@IP` / `analyst2024` |
| 214 | ctf-network-recon | 192.168.10.214 | FTP anon, hidden service, port knocking (3 flags) | Scan from Kali — no creds |
| 215 | ctf-scoreboard | 192.168.10.215 | Flag submission & progress tracking | Browser: http://IP |

### CTID range — do not move back to 201–205

CTIDs **201–207** are the FAE practice labs and are actively in use. **300** is the production dfwagentops.com web server; **100/900/901** are a VM and two OpenClaw templates. `deploy.sh` hard-refuses to touch any of them: it whitelists only the five CTIDs derived from its own `CONTAINERS` map, and carries an explicit deny list on top.

## Containers are unprivileged

Since the 2026-07-28 rebuild these run `--unprivileged 1` with **no** `nesting` feature (previously privileged + `nesting=1`).

These containers are deliberately vulnerable *and* reachable from the Kali VLAN. Solving a privesc challenge is supposed to yield root **in the container** — under a privileged LXC that same root is effectively root on the PVE host, which also runs production CT 300 and the backup shares. No challenge setup script uses docker, mount, or modprobe, so nothing needed the privilege.

If a future challenge genuinely requires nesting, re-add it for that one CTID only and keep it unprivileged.

## Management

Deploy scripts on both machines:
- **Proxmox host**: `/root/ctf/deploy.sh`
- **Local**: `ctf/deploy.sh` (in this repo)

Commands (run on Proxmox host):
```bash
bash /root/ctf/deploy.sh status            # Show all containers
bash /root/ctf/deploy.sh deploy all        # Deploy everything fresh
bash /root/ctf/deploy.sh reset web         # Wipe & redeploy one challenge
bash /root/ctf/deploy.sh destroy all       # Tear down everything
```

Notes on the deployer (hardened 2026-07-28):
- **`destroy` and `reset` require an explicit target.** There is no `all` default for destructive verbs — a forgotten argument used to mean "destroy everything."
- **Non-interactive safe.** Over `ssh root@host bash /root/ctf/deploy.sh ...` there is no TTY, so confirmation prompts default to **NO** rather than hanging or silently proceeding. Set `CTF_ASSUME_YES=1` to pre-authorise.
- **Batch-tolerant.** One failing challenge no longer aborts the remaining containers. Exit codes: `0` all OK, `1` usage/guard error, `2` one or more targets failed or were skipped.
- **Run it as a file**, never `bash -s < deploy.sh` — piping sets `$0` to `bash` and every challenge setup script fails to resolve.

## Known Issues
- Container root password for all CTF containers: `ctfadmin123`

## Network access

- **Primary path — Kali (VirtualBox) over Tailscale**: the attack machine is a travelling Kali VM joined to the tailnet. It reaches the CTF containers at their LAN IPs through the subnet route the Proxmox host (`100.81.116.89`) advertises. **No firewall change needed; confirmed working 2026-07-28.**
- **From the lab LAN** (VLAN 10, `192.168.10.0/24`): direct access to all CTF IPs.
- **Optional — a Kali physically on VLAN 70** (`192.168.77.0/24`): would reach the lab only via the UniFi Dream Machine firewall whitelist, which covers `192.168.10.201-205` and would need widening to `.211-.215`. This is **not** the access path in use (Tailscale is), so it's optional, not blocking. It also covers Proxmox host `.147` and web server `.220`; do not broaden it to all VLAN70→VLAN10 traffic.
