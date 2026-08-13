# FAE Practice Labs — Design Spec

**Date:** 2026-07-04 · **Status:** Approved, in build
**Goal:** Three isolated, re-armable Proxmox LXC labs for practicing hands-on Linux, networking, and troubleshooting for a Field Application Engineer role. Accessed remotely over Tailscale from an Ubuntu machine.

---

## 1. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Existing CTF 201-205 | **Tear down** | Frees CTIDs/IPs. Reversible: `bash /root/ctf/deploy.sh deploy all` (deploy.sh + 5 setup.sh verified present in repo AND `/root/ctf/`). |
| Access model | **Dual-NIC** | `eth0` mgmt on vmbr0 (Tailscale-reachable, never touched by faults) + `eth1` on an isolated bridge where all breakage lives. Cannot self-lock-out; breakage cannot leak to the real LAN. |
| VPN stack | **OpenVPN** | Closer to legacy-enterprise customer sites; richer `systemctl`/journal surface to practice on. |
| Re-arm | **Proxmox snapshot rollback** | Snapshot `lab_armed` taken post-break; `reset` rolls back instantly regardless of how badly the box was mangled while troubleshooting. |
| Faults per lab | **3** | Each rung requires a *different diagnostic tool* to find. |
| Container type | **Privileged + `nesting=1`** | Matches existing CTF containers; required for OpenVPN TUN access. |
| Template | `debian-12-standard_12.12-1_amd64.tar.zst` (on `local`) | Same as existing lab. |

## 2. Topology

Two new **isolated** bridges (`bridge-ports none`, no uplink, no host IP):
- `vmbr1` — Lab 1 segment (`10.10.10.0/24`)
- `vmbr2` — Lab 2 segment (`10.20.20.0/24`)

| CTID | Name | eth0 mgmt (vmbr0) | eth1 lab | Lab |
|---|---|---|---|---|
| 201 | `lab-router-a` | 192.168.10.201/24 gw .1 | vmbr1 · 10.10.10.10/24 | 1 |
| 202 | `lab-router-b` | 192.168.10.202/24 gw .1 | vmbr1 · 10.10.10.20/24 *(broken)* | 1 |
| 203 | `lab-vpn-a` | 192.168.10.203/24 gw .1 | vmbr2 · 10.20.20.10/24 | 2 |
| 204 | `lab-vpn-b` | 192.168.10.204/24 gw .1 | vmbr2 · 10.20.20.20/24 | 2 |
| 205 | `lab-logs` | 192.168.10.205/24 gw .1 | — | 3 |

Resources per CT: 1 core, 512MB–1GB RAM, 8GB disk on `local-lvm`.

### Mgmt-path invariant (non-negotiable)
`eth0`, its address, and the **default route via 192.168.10.1** are never modified by any fault. `eth1` is configured in Proxmox with **no gateway** — a default route on the lab NIC would hijack the mgmt route and sever SSH/Tailscale. Every `break.sh` ends with a guard asserting the mgmt default route and eth0 address are intact, and aborts loudly if not.

## 3. Faults

### Lab 1 — Broken Router (CT 201/202)
Ticket: *"Container A cannot ping Container B."* Ladder, in discovery order:

1. **Subnet mask mismatch** — B's `eth1` is `/28` (10.10.10.16–31), placing A's `.10` outside B's subnet. A ARPs fine and the echo request *arrives*; B cannot reply on-link. Symptom: `tcpdump` shows request-in / no-reply. Tool: `ip addr`, `tcpdump`.
2. **Bogus next-hop** — scoped static route for the lab subnet via non-existent `10.10.10.254`. Tool: `ip route`.
3. **Poisoned ARP entry** — permanent (`nud permanent`) neighbour entry on A mapping B's IP to a bogus MAC. Everything in L3 config now reads correct, yet traffic still dies. Tool: `ip neigh`.

Optional alternate scenario (selectable): ICMP `DROP` rule — teaches "ping is not ground truth" (TCP works while ping fails).

### Lab 2 — Tunnel Failure (CT 203/204, OpenVPN)
Tunnel **comes up green** (`systemctl status` = active) — deliberate red herring. Ladder:

1. **`net.ipv4.ip_forward=0`** on one endpoint — traffic arrives but is never forwarded between `tun0` and `eth1`. Tool: `sysctl`, `/proc/sys/net/ipv4/ip_forward`.
2. **Missing return route** — far-side subnet not routed back. Tool: `ip route`.
3. **MTU black-hole** — `tun-mtu` vs a lowered underlay MTU with `mssfix 0`; small pings succeed, large payloads hang. The real-world "ping works, scp dies" ticket. Tool: `ip link`, `ping -M do -s`, `tracepath`.

### Lab 3 — Raw Log Playground (CT 205)
No faults to fix — a parsing target. Generated artifacts:
- `/var/log/syslog` — 10,000 chronologically-ordered lines, realistic `Mon DD HH:MM:SS host proc[pid]:` format. Background noise (cron, systemd, dbus, sshd, kernel) interspersed with **clustered bursts** (not random scatter, so correlation is learnable) of four signal classes:
  1. NIC link flaps (`e1000e ... NIC Link is Down/Up`)
  2. TCP retransmission timeouts
  3. USB peripheral disconnects
  4. OOM-killer / disk I/O errors
- `/var/log/auth.log` — companion file with failed-auth bursts **time-correlated** to the NIC flaps, forcing a cross-file join.
- **Edge cases on purpose:** a handful of malformed/corrupted-timestamp lines, plus a gzipped `syslog.1` — the parser must survive rotation and bad input.
- Optional `log-trickle.service` (**disabled by default**) appends live lines for `tail -f` practice.

## 4. Access & re-arm

- `openssh-server` + user `fae`, seeded with the pubkeys already in the Proxmox host's `/root/.ssh/authorized_keys` so existing Ubuntu keys work immediately.
- Field ticket written to `/root/FIELD_TICKET.txt` **and** `/etc/motd` so it greets on SSH login. Tickets describe the *user complaint only* — never the fault.
- Post-break snapshot `lab_armed` on each CT. `deploy.sh reset <lab>` rolls back.

## 5. Deliverables

```
labs/
├── deploy.sh                    # deploy|break|reset|status|destroy [lab1|lab2|lab3|all]
├── lib/common.sh                # shared helpers; LXC gotchas baked in
├── lab1-broken-router/{setup.sh,break.sh,FIELD_TICKET.txt}
├── lab2-tunnel-failure/{setup.sh,break.sh,FIELD_TICKET.txt}
├── lab3-log-playground/{setup.sh,gen-syslog.sh}
├── README.md                    # teaching guide (methodology, commands, progressive hints)
└── SOLUTIONS.md                 # spoilers, deliberately separate
```

**LXC gotchas applied** (from `lxc-gotchas.md`): #5 wait-for-network before apt, #6 locale suppression, #7 install curl, #10 verification block ending every setup script. #3 (`eth0@ifN` naming) is directly relevant — never auto-detect interface names in the network labs; hardcode `eth0`/`eth1`.

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **TUN in LXC** blocks OpenVPN | Smoke-test `/dev/net/tun` passthrough (`lxc.cgroup2.devices.allow: c 10:200 rwm` + `/dev/net` bind) in a throwaway CT **before** building lab 2. Host `/dev/net/tun` confirmed present. |
| **Host bridge creation** could break networking | Back up `/etc/network/interfaces`; add bridges with `bridge-ports none`; bring up with `ifup vmbr1` individually — **never** `systemctl restart networking`; verify vmbr0 + SSH after each step. |
| **Default-route hijack** severs mgmt | `eth1` configured with no gateway; faults use scoped static routes only; guard assertion in every break script. |
| Netfilter behaviour in LXC | ARP-poisoning chosen as Lab 1 fault 3 (pure userspace, guaranteed). Firewall variant is optional/secondary. |
| Stale docs | `ctf-lab.md` marked decommissioned with the one-line rebuild command. |

## 7. Build sequence

1. Tear down CT 201-205 (verify rebuild path first).
2. Create vmbr1/vmbr2; verify host networking survives.
3. TUN smoke test (de-risk lab 2).
4. Author scripts (parallel subagents).
5. **Mandatory dual review**: `engineering-code-reviewer` + `codex exec` in parallel → apply CRITICALs from either → re-syntax-check → deploy.
6. Deploy, verify each fault armed + mgmt SSH intact, snapshot `lab_armed`.
7. Write README.md + SOLUTIONS.md; update CLAUDE.md / CHANGELOG.md.
