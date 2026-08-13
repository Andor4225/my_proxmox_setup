# Windows Backup Runbook — Samba over Tailscale → Proxmox

Built 2026-04-29. Backs up the Windows machine to the external USB-C SSD enclosure on Proxmox via two SMB shares over Tailscale.

---

## 🟡 STATUS 2026-05-20 — interim on internal SATA; enclosure RMA pending

The ASMedia 3-bay USB enclosure is faulty (Phase 2 testing confirmed: all three NVMe drives are healthy; the *bridge silicon* is intermittently bad across multiple channels). RMA pursued via Amazon. Backups have been relocated to the internal SATA partition with **no Samba share name changes** — Windows configs keep working as-is.

| Share name (UNC, unchanged) | Now points to | Holds |
|---|---|---|
| `\\100.81.116.89\backup-files` | `/mnt/pve-backups/windows-backups/restic` | Restic repo (empty, ready for `restic init`) |
| `\\100.81.116.89\backup-images` | `/mnt/pve-backups/windows-backups/veeam` | Salvaged 143GB Veeam image (`Windows Backup/Windows Backup2026-04-29T140913.vbk`) |

**Capacity is tight:** 44GB free of 196GB after the salvaged image. **Set Veeam retention to "keep last 1 full"** until storage is added — otherwise the next full will fill the partition. Restic deduplication keeps file-level backups small (10s of GB).

The previous restic repo (on the failing sdc drive) is treated as **lost** — source files intact on Windows, just re-init a fresh repo on the new path. Old USB mountpoints (`/mnt/{backup-files,backup-images,fast-tier}`) remain as empty bare dirs with `noauto` in fstab — harmless, ready for reuse if a working enclosure arrives.

**Wedge-break (if the enclosure is ever re-authorized and the host load climbs with `usb-storage`/`jbd2-sdc` D-state + USB resets every ~38s):**
```bash
ssh root@100.81.116.89
systemctl stop smbd --no-block
echo 0 > /sys/bus/usb/devices/2-4/authorized   # D-state clears in seconds
umount -l /mnt/backup-files /mnt/backup-images /mnt/fast-tier 2>/dev/null
```

**Next steps (open):**
1. **Physical fault isolation** — power down enclosure, pull all 3 NVMe. Test sdc's stick alone in slot 1 (errors → bad drive). Test that slot with a known-good stick (errors → bad slot/bridge channel). Result tells you: replace one NVMe / avoid one slot / replace the whole enclosure.
2. **Pick a reliable target** — single-drive enclosure with JMicron JMS583 or Realtek RTL9210b bridge (~$25-40, the real fix), or internal `sata-backups` (reliable, ~200GB, interim), pending #1.
3. Re-init restic fresh on the chosen target; re-point Veeam there too.
4. Move/verify the salvaged Veeam image to its final home; confirm with Veeam's own "Validate backup".

The SMB-over-Tailscale + Samba-lock infrastructure (sections below) is sound and reusable once the storage hardware is replaced — only the physical drives/enclosure are the problem.

---

## What's already done (Proxmox side)

- Three external NVMe drives mounted (`/mnt/fast-tier`, `/mnt/backup-files`, `/mnt/backup-images`)
- Samba 4.22 installed and configured (standalone, SMB2+, signing required)
- nftables `samba_lock` table restricts TCP 139/445 to `lo` + `tailscale0` only
- `gavin` Linux user created (uid 1000), owns both backup mounts (0750)
- `samba-lock.service` makes nftables rules persistent across reboots

## What you need to do

### Step 1 — Set the Samba password (one-time, on Proxmox)

```bash
ssh root@100.81.116.89
smbpasswd -a gavin
# Enter a strong password twice. Save it in your password manager.
exit
```

This password is used by Windows to authenticate to the SMB shares. It's separate from the Linux user password (which doesn't exist — `gavin` has `nologin` shell).

### Step 2 — Verify Tailscale is up on Windows

In an admin PowerShell:
```powershell
tailscale status
# Should show proxmox-pve  100.81.116.89  online
Test-NetConnection 100.81.116.89 -Port 445
# TcpTestSucceeded : True
```

If port 445 fails: confirm Windows is on the tailnet, and that the Proxmox `samba-lock.service` is active (`ssh root@100.81.116.89 'systemctl is-active samba-lock smbd'` should show both `active`).

### Step 3 — Mount the SMB shares on Windows

In File Explorer → right-click "This PC" → Map Network Drive:

| Drive letter | Path | Use |
|---|---|---|
| `Z:` | `\\100.81.116.89\backup-images` | Macrium Reflect target |
| `Y:` | `\\100.81.116.89\backup-files` | Restic repo |

Check "Connect using different credentials" → username `gavin`, password from Step 1. Check "Reconnect at sign-in" only if you want them auto-mounted (not required for backups since both tools take the UNC path directly).

Alternative (PowerShell, no drive letter — recommended for backups):
```powershell
$cred = Get-Credential gavin
New-SmbMapping -RemotePath '\\100.81.116.89\backup-images' -Username 'gavin' -Password (ConvertFrom-SecureString -AsPlainText $cred.GetNetworkCredential().Password)
# (and same for backup-files)
```

Or just use the UNC path directly in Macrium / Restic without mounting at all (cleaner).

---

## Bare-metal image backups → Macrium Reflect Free

### Install
1. Download Macrium Reflect Free Edition: https://www.macrium.com/reflectfree
   - Note: Macrium ended Free as of v8.0.7783 in January 2024 but the last free build is still downloadable. If gone, alternative: **Veeam Agent for Microsoft Windows Free**.
2. Install with default options.

### Configure first backup
1. Launch Macrium → "Create a backup" → "Backup an entire disk".
2. Select the source disk (your Windows OS drive).
3. Destination: enter `\\100.81.116.89\backup-images\windows-images` (let it create the folder).
4. When prompted for SMB credentials: username `gavin`, password from Step 1, **check "Save credentials"** (Macrium stores them in its own encrypted vault).
5. Schedule:
   - **Full**: Sundays 2:00 AM
   - **Differential**: Mon/Wed/Fri 2:00 AM
   - **Retention**: keep 4 fulls + 12 differentials (~4 weeks rolling)
6. Compression: medium. Encryption: AES-256, set a passphrase, save in password manager.

### Recovery (Windows broken, bare metal)
1. Boot the **Macrium Rescue Media** USB (create this from Macrium → "Other Tasks → Create rescue media" — do this NOW, not after a crash).
2. The rescue media has Tailscale support? **No, it doesn't.** Two options:
   - **Connect a USB cable**: temporarily plug the SSD enclosure directly into the recovering machine.
   - **Use Tailscale on rescue media**: Macrium WinPE supports drivers; you can integrate Tailscale's Windows installer. Search "Macrium Reflect WinPE Tailscale" — there are guides. More setup but means recovery works without physically moving the enclosure.
3. Restore the latest image to a target disk.

**Strong recommendation: practice a recovery into a Hyper-V or VirtualBox VM once a quarter.** A backup you've never restored is just hopeful thinking.

---

## File-level backups → Restic

Restic is encrypted, deduplicated, snapshot-based. Tiny incrementals, fast restores of single files.

### Install on Windows
```powershell
winget install restic.restic
# or download from https://restic.net/
```

### Initialize the repo (one-time)
```powershell
$env:RESTIC_REPOSITORY = '\\100.81.116.89\backup-files\restic'
$env:RESTIC_PASSWORD = '<strong-random-passphrase-save-in-password-manager>'
restic init
```

If SMB credentials prompt: username `gavin`, password from Step 1.

**The Restic passphrase encrypts the repo. If you lose it, the backups are unrecoverable. Save it in your password manager AND a second offline location (printed on paper, etched in steel, whatever).**

### First backup
```powershell
restic backup C:\Users\Gavin\Desktop C:\Users\Gavin\Documents C:\Users\Gavin\Pictures
```

Add other paths as desired. First run uploads everything; subsequent runs only upload changed/new chunks.

### Schedule (Task Scheduler)
Create a scheduled task running hourly (or whatever cadence) that runs:
```powershell
$env:RESTIC_REPOSITORY = '\\100.81.116.89\backup-files\restic'
$env:RESTIC_PASSWORD_FILE = 'C:\Users\Gavin\.restic-pass'  # store passphrase in a 600-perm file
restic backup C:\Users\Gavin\Desktop C:\Users\Gavin\Documents C:\Users\Gavin\Pictures
restic forget --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

The `forget` line keeps a rolling window: 24 hourly, 14 daily, 8 weekly, 12 monthly snapshots. Adjust to taste.

### Restore (lose a single file or folder)
```powershell
restic snapshots                                        # list snapshots
restic restore <snapshot-id> --target C:\restored --include /Users/Gavin/Documents/budget.xlsx
```

Or mount the repo as a virtual filesystem:
```powershell
restic mount Z:\restic-mount   # browse all snapshots like a file tree
```

---

## What's where (quick reference)

| Thing | Location |
|---|---|
| Linux user owning both shares | `gavin` (uid 1000) on Proxmox |
| Samba config | `/etc/samba/smb.conf` (backup at `.orig`) |
| nftables lock | `/etc/nftables.d/samba-lock.nft` + `samba-lock.service` |
| Macrium image target | `\\100.81.116.89\backup-images\windows-images` |
| Restic repo | `\\100.81.116.89\backup-files\restic` |
| Restic passphrase | Password manager + offline copy |
| Macrium image passphrase | Password manager |

## Troubleshooting

**Can't reach 445**: `tailscale status` (is Tailscale up?), then `ssh root@100.81.116.89 'systemctl is-active samba-lock smbd'` (both should be `active`), then `ssh root@100.81.116.89 'nft list table inet samba_lock'` (rules should be loaded).

**Auth fails**: re-run `smbpasswd -a gavin` on Proxmox to reset the SMB password.

**Slow speed**: Tailscale uses UDP encrypted tunneling; expect ~80–200 Mbps over residential WiFi. For first full Macrium image (200–400 GB), plug the laptop into ethernet — could take overnight on first run, much faster after.

**Backups silently stopped / share serves empty folder**: the USB enclosure dropped off the bus and the mount didn't come back. As of 2026-05-19 this self-heals — the 3 mounts use `x-systemd.automount`, so next access re-mounts automatically if the device is present. To check on Proxmox:
- `lsblk | grep usb` — are `sdb/sdc/sdd` present? If missing, the enclosure fully dropped: replug the USB-C cable, then `ls /mnt/backup-files/restic/config` to trigger the automount.
- `lsusb -t` — the ASM246X **must** show `Driver=usb-storage`. If it shows `Driver=uas`, the UAS quirk isn't active (check `/proc/cmdline` for `usb-storage.quirks=174c:0c17:u`); UAS will keep dropping the bus under write load.
- `dmesg | grep -iE 'uas|abort|offline'` — recurring `uas_eh_abort_handler` = quirk not applied.
- After an unclean drop, run `fsck.ext4 -n /dev/sdX` (read-only) before relying on the data; `-y` if it reports errors (journal-recovery counter fixes are harmless).

**Root cause (fixed 2026-05-19)**: ASMedia ASM246X + Linux `uas` driver is unstable under sustained writes — the 2026-05-18 incident dropped the whole enclosure for ~33h. Permanent fix: `usb-storage.quirks=174c:0c17:u` kernel cmdline forces the stable BOT driver. Don't remove it.

**`samba_lock` rules wiped after enabling Datacenter Firewall**: `systemctl restart samba-lock`. Long-term: migrate the rules into Proxmox's firewall config (`/etc/pve/firewall/cluster.fw`).
