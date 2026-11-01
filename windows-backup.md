# Windows Backup Infrastructure (Samba over Tailscale)

Backs up the Windows machine to the OWC Express 4M2 NVMe enclosure on Proxmox via SMB over Tailscale.

> **Operational runbook** (setting Samba password, mapping shares from Windows, Veeam/Restic setup, recovery scenarios) lives in `plans/windows-backup-runbook.md`. This file covers the architecture / what's deployed.

## Topology
- Backups land on the **OWC Express 4M2** USB-C enclosure: `/mnt/backup-files` (restic, 500GB drive) and `/mnt/backup-images` (Veeam, 512GB drive). Mounts use `x-systemd.automount,nofail` — self-heal after a reboot or replug.
- Samba binds to all interfaces (POINTOPOINT `tailscale0` won't bind via Samba's `bind interfaces only`).
- nftables `samba_lock` table restricts TCP 139/445 to `lo` + `tailscale0` only — LAN-side requests are dropped.
- Persistence: `samba-lock.service` (systemd oneshot) reloads `/etc/nftables.d/samba-lock.nft` after `tailscaled` and `pve-firewall` on boot.

## Shares
| UNC path (Tailscale) | Path on Proxmox | Purpose |
|---|---|---|
| `\\100.81.116.89\backup-files` | `/mnt/backup-files` (restic repo in `restic/` subdir) | Restic encrypted file-level repo |
| `\\100.81.116.89\backup-images` | `/mnt/backup-images` (Veeam job folder inside) | Veeam bare-metal images |

Both owned by `gavin:gavin`, mode `0750`. Auth: SMB user `gavin` (Linux user, no shell, Samba password set via `smbpasswd -a gavin`).

**Capacity**: each OWC drive has ~445 GB usable.
- Restic (deduplicated) is small.
- **The Veeam target IS capacity-constrained.** A forever-forward image of C: (full ~190-270 GB plus ~15-90 GB daily increments, 3-day retention) fills it twice over in months; see CHANGELOG 2026-09-02 and 2026-11-01.
- **Rules:**
  - keep reproducible bulk off C:;
  - keep Veeam's "Defragment and compact full backup file" **OFF**, because it needs a second full's worth of free space;
  - when the target fills, trim C: and reset the chain (delete the chain files on the host, then Back Up Now).

## Config files (on Proxmox host)
| File | Purpose |
|---|---|
| `/etc/samba/smb.conf` | Standalone server, SMB2+ minimum, signing required, no printers, two share definitions |
| `/etc/nftables.d/samba-lock.nft` | nftables table `samba_lock` — drops 139/445 from non-allowed interfaces |
| `/etc/systemd/system/samba-lock.service` | Reapplies the nftables rules on boot |

## Service status
- `smbd` enabled and active
- `nmbd` disabled (NetBIOS broadcasts can't traverse Tailscale; not needed when accessing by IP)
- `samba-ad-dc` disabled (was auto-enabled by Debian 13 `samba` package; not used in standalone mode)
- `samba-lock.service` enabled and active

## Caveat: pve-firewall
If Datacenter Firewall is ever enabled in the Proxmox UI, `pve-firewall` will `nft flush ruleset` and wipe `samba_lock`. The `samba-lock.service` runs after `pve-firewall.service` on boot, so reboots are fine — but a manual `pve-firewall reload` will leave a window where SMB is exposed to all interfaces. Re-run `systemctl start samba-lock` after any pve-firewall reload, or migrate the rules into Proxmox's firewall config.

## Monitoring

A daily health check guards against silent backup failures (the failure class behind every past incident):

- **Script**: `/usr/local/sbin/backup-health-check.sh` on the host (source: `scripts/backup-health-check.sh` in this repo).
- **Schedule**: `backup-health-check.timer` — daily ~09:00.
- **Checks**: OWC mounts are real ext4 block devices, free space, restic + Veeam backup freshness (newest-file age vs 36h/48h thresholds), and USB bridge errors in the kernel log.
- **Exit codes**: 0 healthy, 1 warning(s), 2 failure(s) — a non-zero exit marks the systemd unit failed. Output also appends to `/var/log/backup-health-check.log`.
- **Alerting**: OpenClaw (24/7 monitor on the Pi) consumes the result. Its proxmox health check runs ~3×/day — it triggers `backup-health-check.service`, reads `ExecMainStatus`, and on a non-zero exit posts the `[WARN]`/`[FAIL]` detail lines to the **security** Discord channel. Healthy runs (exit 0) are silent — alerts fire only on an actual issue. The daily `backup-health-check.timer` stays enabled as a backstop (same service, no conflict).
- Run on demand: `systemctl start backup-health-check.service` then check the log, or run the script directly.

## Hardware history
- **2026-04-29 → 2026-05-20**: original target was a 3-bay ASMedia ASM246X USB enclosure ($200). Its bridge silicon was defective — intermittent channel failures repeatedly wedged the Proxmox host. RMA'd 2026-05-20. Backups were moved to the internal 200GB SATA partition as an interim measure.
- **2026-05-22**: replaced with an **OWC Express 4M2** 4-bay NVMe enclosure (USB ID `1e91:de83`). Passed a 30GB write-verify stress test with zero bridge resets (~520 MB/s write, ~715 MB/s read). The 3 NVMe sticks moved into it; backups migrated off the cramped internal partition onto the OWC. 4th bay is free for expansion.

See `CHANGELOG.md` for the full incident history. The enclosure validation tool is `scripts/owc-stress-test.sh` — re-runnable if a drive is added or hardware is swapped.
