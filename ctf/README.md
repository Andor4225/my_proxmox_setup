# Proxmox CTF Lab

A self-contained, 5-container Capture-The-Flag lab on the Proxmox pentest lab. **13 flags, 2500 points**, spanning web exploitation, Linux privilege escalation, crypto/forensics, and network recon, with a live scoreboard.

> **This file is spoiler-free.** It tells you how to reach the lab, what each target is, and how to score. Full walkthroughs and every flag value live in [SOLUTIONS.md](SOLUTIONS.md) — don't open it until you've had a real go.

---

## Targets

| CTID | Target | IP | Category | Flags | Points | First access |
|---|---|---|---|---|---|---|
| 211 | ctf-web-exploit | `192.168.10.211` | Web exploitation | 3 | 600 | Browser → `http://192.168.10.211/` |
| 212 | ctf-linux-privesc | `192.168.10.212` | Privilege escalation | 4 | 800 | `ssh ctfplayer@192.168.10.212` (pw `ctfplayer123`) |
| 213 | ctf-crypto-forensics | `192.168.10.213` | Crypto & forensics | 3 | 600 | `ssh analyst@192.168.10.213` (pw `analyst2024`) |
| 214 | ctf-network-recon | `192.168.10.214` | Network recon | 3 | 500 | Scan it from Kali — no creds given |
| 215 | ctf-scoreboard | `192.168.10.215` | — | — | — | Browser → `http://192.168.10.215/` |

Flags are all in the format `FLAG{...}`. Difficulty within each box runs Easy (100) → Medium (200) → Hard (300).

---

## Getting in

### From Kali over Tailscale (the working path)

The attack machine is **Kali running in VirtualBox**, joined to the tailnet — it travels, and connects from wherever it happens to be. Any device on the tailnet reaches the targets at their LAN IPs through the subnet route the Proxmox host advertises, so this needs **no firewall change** and is the confirmed-working path:

```bash
nmap -sV -p- 192.168.10.211-215        # enumerate everything at once
ssh ctfplayer@192.168.10.212           # or reach an individual box
```

The Kali VM SSH key (`kali@kali`) is installed on the Proxmox host itself (`ssh root@100.81.116.89`), which is separate from the CTF containers (those use the passwords above).

---

## The five targets

**211 — Web Exploitation.** A "MegaCorp" web app on port 80. Three classic web bugs of increasing difficulty: an authentication/data-extraction flaw in the login form, a stored-content flaw that lets you steal a privileged session, and a server-side request flaw in a URL-preview feature that reaches something you're not supposed to see. Start at the home page and read everything, including `robots.txt`.

**212 — Linux Privilege Escalation.** You log in as the unprivileged `ctfplayer`. Four independent paths from user to root, each dropping a flag readable only once you've escalated: a misconfigured SUID binary, a writable script a root cron job runs, a sudo rule that's more generous than it looks, and a file permission that should never be what it is. Several deliberate red herrings are planted — not every SUID binary or interesting-looking file is the way in. `sudo -l` and a look around `/opt`, `/etc/cron*`, and the SUID set are the obvious first moves.

**213 — Crypto & Forensics.** You log in as `analyst` with an `evidence/` directory and a `tools/` directory. Three artifacts to work: an encoded message, an image hiding something past its visible end, and a web access log recording an exfiltration you must reconstruct and decrypt. The `tools/` directory contains a helper you'll want for the last one. Some files in `evidence/` are decoys with their own dead ends.

**214 — Network Recon.** No credentials. You get an IP and nothing else — everything starts with a scan. Anonymous FTP is the first thread; pull on it and it leads to a custom service on a high port, which in turn leads to a knock-to-open SSH backdoor. Each stage hands you what you need for the next. This is a chain: solve it in order.

**215 — Scoreboard.** Tracks all 13 flags and 2500 points. Submit flags here as you capture them (see below).

---

## Scoring

Open `http://192.168.10.215/` and submit each `FLAG{...}` string as you find it. The scoreboard knows all 13 flags, their categories, and their point values, and shows running progress. It only records the capture — it doesn't help you get there.

A rough order that matches the difficulty curve: **214 (network chain)** and the Easy flags on each box first, then the Mediums, then the three Hard flags (SSRF on 211, writable-passwd on 212, XOR log analysis on 213, port-knocking on 214).

---

## Managing the lab (Proxmox host)

The deployer lives at `/root/ctf/deploy.sh` on the host (and in this repo). Run it **as a file**, not piped.

```bash
bash /root/ctf/deploy.sh status              # show all five containers
bash /root/ctf/deploy.sh deploy all          # build everything fresh
bash /root/ctf/deploy.sh reset network       # re-arm one box from scratch
bash /root/ctf/deploy.sh destroy all         # tear the lab down
```

- **`reset` is your friend.** Solved a box, or broke it while exploring? `reset <target>` destroys and redeploys just that one in a minute or two, flags freshly placed. `reset` and `destroy` require an explicit target — there's no "all" by default.
- **Over SSH there's no terminal to confirm on**, so destructive commands default to *no*. To script them: `CTF_ASSUME_YES=1 bash /root/ctf/deploy.sh reset web`.
- The deployer refuses to touch any CTID that isn't one of its own five (211–215) — the FAE labs (201–207), the production web server (300), and the VM templates are hard-protected.

### Container internals

- Containers are **unprivileged** (root inside is not root on the Proxmox host — these are deliberately vulnerable boxes, so that containment matters).
- Root password inside every container is `ctfadmin123` (via `pct enter <ctid>` from the host if you need to peek — but that's cheating).
- Port-knock, service ports, and creds for the challenges themselves are all discoverable in-lab; they're written up in SOLUTIONS.md if you get stuck.

---

## Files

```
ctf/
├── README.md                       # this file (spoiler-free)
├── SOLUTIONS.md                    # full walkthroughs + every flag (spoilers)
├── deploy.sh                       # container deployer / manager
├── challenges/
│   ├── web-exploit/setup.sh        # CT 211
│   ├── linux-privesc/setup.sh      # CT 212
│   ├── crypto-forensics/setup.sh   # CT 213
│   └── network-recon/setup.sh      # CT 214
└── scoreboard/setup.sh             # CT 215
```

See [`../ctf-lab.md`](../ctf-lab.md) for how this lab fits into the wider Proxmox environment, and [`../lxc-gotchas.md`](../lxc-gotchas.md) for the LXC setup-script traps these challenges are built to survive.
