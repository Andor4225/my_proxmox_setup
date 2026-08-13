# my_proxmox_setup

Infrastructure, automation, and documentation for a home **Proxmox VE** pentest lab — plus the TypeScript **MCP server** that drives it. This repo is the version-controlled, cloud-backed source of truth for the lab so it can be understood, audited, and rebuilt.

> **Private repo, but treated as if it weren't.** No secrets are committed. The Proxmox API token lives only in a gitignored `.env`; build artifacts, local tooling state, and machine-specific files are excluded. See [Security](#security) below.

---

## What's here

| Path | What it is |
|---|---|
| `CLAUDE.md` / `AGENTS.md` | Current-state overview of the whole lab (host specs, storage, networking, VMs/CTs, automation). The single best starting point. |
| `CHANGELOG.md` | Dated history of every substantive change to the lab. |
| `src/` | TypeScript MCP server (`index.ts` + `proxmox-client.ts`) wrapping the Proxmox REST API + SSH — 18 tools for VM/CT/snapshot/Docker management. |
| `ctf/` | Self-contained CTF lab: 5 LXC containers, 13 flags, a deployer, and per-challenge setup scripts. See `ctf/README.md` (spoiler-free) and `ctf/SOLUTIONS.md`. |
| `fae/` | Field-Application-Engineer troubleshooting labs: deliberately-broken container environments with a fault-injection deployer. See `fae/README.md`. |
| `scripts/` | Host maintenance scripts (backup health check, semi-monthly `apt` upgrade) deployed to `/usr/local/sbin/`. |
| `systemd/` | systemd units/timers for the automated maintenance above. |
| `plans/` | Saved implementation plans and runbooks. |
| `lxc-gotchas.md` | Hard-won LXC setup-script traps (read before writing any `setup.sh`). |
| `ctf-lab.md`, `windows-backup.md` | Subsystem deep-dives (CTF containers; Samba/Tailscale backup architecture). |

## The MCP server

```bash
npm install
npm run build      # tsc -> dist/index.js
```

The server is configured in `.mcp.json` and needs a `.env` (not committed) providing the Proxmox API token. A self-signed cert on the Proxmox host requires `NODE_TLS_REJECT_UNAUTHORIZED=0` (already set in `.mcp.json`).

Create your own `.env` from this shape:

```dotenv
# .env  — never commit this file
PROXMOX_HOST=<host-ip>
PROXMOX_PORT=8006
PROXMOX_TOKEN_ID=<user@realm!tokenname>
PROXMOX_TOKEN_SECRET=<secret-uuid>
```

## Security

This repo is private, but is maintained as though it could become public at any time:

- **Secrets are never committed.** The API token lives only in `.env`, which is gitignored. No private keys, no credentials in tracked files.
- **Excluded from version control** (`.gitignore`): `.env`, private-key material, `node_modules/`, `dist/`, local tooling state (`.claude/`, `.omc/`), editor/OS cruft, and `*.bak` working files.
- **Lab credentials in `ctf/` are intentionally weak** and are part of the challenges. The containers are unprivileged and reachable only on the internal lab network / tailnet — those passwords are not real secrets.
- Internal IPs and Tailscale addresses are non-routable (RFC1918 + CGNAT) and are kept so the lab can be rebuilt from this repo.

## What is intentionally not here

Some documentation lives in sibling projects and is intentionally excluded from this repo (business/brand material and anything not part of the lab itself). Where a lab doc references such a file, it says so inline.

---

_Rebuilding from scratch? Start with `CLAUDE.md`, then `CHANGELOG.md` for how the current state came to be._
