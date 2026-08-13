# Changelog

Dated events and architectural changes for the Proxmox lab. Newest first. For current state, see [CLAUDE.md](CLAUDE.md).

---

## 2026-08-13

**Repo put under version control and pushed to a private GitHub backup — `github.com/Andor4225/my_proxmox_setup` — after a two-pass secret/PII audit. First commit `3278756`, 47 files.**

- **Goal:** a cloud-backed source of truth so the lab survives a machine loss, with no secrets or personal info committed even though the repo is private.
- **Excluded (`.gitignore`):** `.env` (the only home of the Proxmox API token + a Cloudflare tunnel token), private-key material, `node_modules/`, `dist/`, local tooling state (`.claude/`, `.omc/`), `ClaudeResumeLast.txt`, `*.bak*`, `id_*.pub`, and the two non-lab business/career docs (`dfwagentops.md`, `linkedin-post-brief.md`). Added `.env.example` (placeholder shape) and a repo-root `README.md`.
- **Sanitized:** the `mistag27@` Tailscale-account handle scrubbed from CLAUDE.md + AGENTS.md; the 6 now-dangling `dfwagentops.md` doc-map/tree references in both files replaced with "kept in local tree, not committed" notes. Infrastructure identifiers (internal 192.168.x IPs, Tailscale CGNAT 100.x, hostnames, SSH **public**-key fingerprints) deliberately **kept** — non-routable and needed to rebuild from the backup.
- **`.gitattributes`** forces LF on all tracked text so the Linux-bound shell scripts don't get CRLF-corrupted when cloned/checked out.
- **Private commit identity:** repo-scoped `user.name/email` set to `Andor4225 <Andor4225@users.noreply.github.com>` (LOCAL config only — the global `Gavin Walsh <mistag27@…>` identity is untouched), so no real email enters commit history.
- **Two independent pre-push audits** (a content pattern-sweep + an independent security-reviewer subagent) both returned CLEAR: no hardcoded token, no private keys, no cloud/Cloudflare secret, no real PII. Only accepted lab content flagged (deliberately-weak `ctf/`+`fae/` challenge creds, `FLAG{}` strings, the public jwt.io demo JWT, fake `security@megacorp.io`). Codex was not used for this pass — its Windows sandbox runner is still broken.
- **Post-push verify:** remote HEAD == local, 47 files, confirmed no excluded/secret path present on the remote.
- **Third scanner + automated gate (gitleaks):** ran `gitleaks git` over the history — the only hits were the intentional lab decoys (`MEGACORP-2024`, the jwt.io demo JWT), now allowlisted by exact regex in a committed `.gitleaks.toml` (extends the default ruleset; real secrets still caught). A working-tree scan flagged only the untracked `.env` (positive control — the real secrets provably live nowhere in git). Added a **tracked pre-commit hook** (`hooks/pre-commit` + `core.hooksPath=hooks`) that runs `gitleaks git --staged --redact` and blocks any commit introducing a secret; fail-open-but-loud if gitleaks is absent, distinguishes a finding (exit 1) from a scanner error. Reviewed (0 critical) and functionally tested both ways (blocks a staged fake AWS key; allows clean commits). Enable per clone: `git config core.hooksPath hooks`.
- **Auth note:** the `gh` CLI login had expired, but `git push` works through Git Credential Manager. Pushes are also gated by the session's auto-mode classifier, so they must be run interactively (`! git push`) or via an added `Bash(git push:*)` permission rule.

---

## 2026-07-28

**CTF lab rebuilt on CTIDs 211–215 (unprivileged, static IPs) alongside the FAE labs. Kali SSH key added to the host. Three flag-breaking bugs found by deploying and testing — all three were documented in `lxc-gotchas.md` and none had ever actually been fixed in the scripts.**

### CTF redeploy — new CTID range
The lab was decommissioned 2026-07-04 when its CTIDs 201–205 went to the FAE labs. Rebuilt on **211–215 / `192.168.10.211-215`** so both labs coexist; the FAE containers were never touched. Addressing changed from **DHCP → static** (`gw=192.168.10.1`): the old script used `ip=dhcp` while `ctf-lab.md` documented static IPs, which also made the Kali firewall whitelist unreliable.
- `.211-.215` confirmed unused (ping + ARP) before deploying.
- ⚠️ **Outstanding user action:** the UniFi VLAN70→VLAN10 whitelist still covers `.201-.205` and must be widened to `.211-.215` for Kali. Tailscale access is unaffected.

### Containers are now unprivileged
Was privileged + `nesting=1`; now `--unprivileged 1` with no features. These containers are deliberately vulnerable *and* Kali-reachable, and solving a privesc challenge is *supposed* to give container root — under a privileged LXC that is effectively PVE host root, on a host also running CT 300 (dfwagentops.com production) and the backup shares. Verified no challenge script uses docker/mount/modprobe, and confirmed empirically that SUID still works unprivileged (no `nosuid` on the rootfs; the binary escalates).

### Three flag-breaking bugs, all pre-existing, all caught only by testing
Each was already written up in `lxc-gotchas.md`; the fix had never been applied to the script it described.
- **knockd dead on every deploy (gotcha #3).** `setup.sh` auto-detected the interface via `ip -o link show`, which returns `eth0@if96` in LXC — knockd passes that to pcap and exits with "No such device exists". The `-z` fallback to `eth0` was dead code because the value is never empty. Port knocking (a network-recon flag) had never worked. Hardcoded `-i eth0`; verified the full sequence 7000→8000→9000 → `OPEN SESAME` → iptables rule → 2222 open.
- **SUID bit never set (gotcha #8).** `linux-privesc/setup.sh` ran `chmod u+s` → `chmod 4755` → **`chown root:root`**, and `chown` clears setuid/setgid per POSIX — even when ownership does not change. The binary shipped `-rwxr-xr-x` and the privesc flag was unobtainable, while the script reported success. Reordered to chown-then-chmod; proven on the host both ways.
- **nginx served the default site (gotcha #1).** The vhost was correct and `sites-enabled/default` *was* removed, but `systemctl enable --now nginx` does not reload an already-running unit and apt starts nginx at install time, so port 80 returned "Welcome to nginx!" while the app sat on :8080. Added an explicit `systemctl restart nginx`.

All three fixes were validated by `deploy.sh reset web|privesc|network` from scratch — not by the manual live patches used to diagnose them.

### CT 212 privesc was shipping only 1 of its 4 flags — three stacked `set -e` bugs
Writing the README/SOLUTIONS surfaced that the batch-tolerant deployer (new this session) was logging `setup.sh in ctf-linux-privesc exited non-zero`. The privesc setup script had been **aborting mid-run on every deploy since long before this session**, silently — the old fail-fast deployer would have killed the whole batch, so this had simply never been visible. Three independent `set -euo pipefail` traps, each hidden behind the one before it:
- **Flag 2 (cron) killed the script.** `(crontab -l 2>/dev/null | grep -v ...; echo "$LINE") | crontab -` — on a fresh container root has no crontab, so `crontab -l` exits 1 and `grep -v` exits 1 on empty input; under `set -e` the **subshell** died before `echo` ran and `pipefail` propagated it out. So flags 2, 3 and 4 (cron, sudo, writable-passwd) plus both decoys were **never configured**. Rebuilt as an explicit temp-file construction with `|| true` guards.
- **The two decoy SUID binaries had the same chown-after-chmod bug** as the real one, so `sysinfo` and `healthcheck` shipped non-SUID — the red herrings silently did not exist. (The real `statuscheck` was already fixed above.)
- **The self-verify block killed the script on its first PASS.** `((PASS++))` returns exit status 1 when `PASS` is 0 (post-increment yields the old value, 0 → arithmetic-false), and under `set -e` that aborted the script on the very first passing check — so even after the earlier fixes it still exited non-zero. Changed to `PASS=$((PASS+1))` / `FAIL=$((FAIL+1))`.
- After all three: the container's own self-check reports **15 passed, 0 failed**, and all four privesc vectors (SUID PATH-hijack, writable cron, sudo/vim, writable /etc/passwd) were confirmed exploitable from the `ctfplayer` account. This is the clearest evidence yet that the batch-tolerance + per-target exit-2 changes to `deploy.sh` earn their keep: they converted a silent 3-flag loss into a visible warning.

### privesc setup.sh review (Code Reviewer) — 2 CRITICAL, applied
After the three fixes, a Code Reviewer pass found the fixes correct but surfaced a deeper issue: **the script always exited 0 regardless of its own verify tally**, so `deploy.sh`'s "setup.sh exited non-zero" guard could never fire on a verification failure — a half-configured challenge would still ship looking successful. Fixed: the verify block's `FAIL` count now drives `exit 1` (C-1), and the bare `crontab "$TMP_CRON"` install is guarded so a failure surfaces as a `[FAIL]` in the tally rather than aborting the whole script (C-2). Also applied the useful DEFENSIVE/COSMETIC findings: swapped the last inverted `chmod 0777; chown` pair on `backup.sh` (uniform chown-first rule so no future edit reintroduces the setuid bug), `groupadd`/`mkdir -p` guards on the standalone-rerun paths, two new verify checks (`vim` present for flag 3, `sshd -t` config valid), and anchored the tally's `grep` matches. Re-deployed from scratch: **17 passed, 0 failed**, all four vectors still exploitable. Codex's parallel pass returned clean findings but again carried the `windows sandbox … runner pipe-in` error mid-trace, so the Code Reviewer was the trusted reviewer.

### Docs
Wrote `ctf/README.md` (spoiler-free: access, per-target briefs, scoring, management) and `ctf/SOLUTIONS.md` (full walkthroughs + all 13 flags, cross-checked byte-for-byte against the scoreboard's flag list). Every flag value, seeded credential, and helper-script signature in the walkthroughs was verified against the live containers. Added `lxc-gotchas.md` #11 (chown clears setuid) and #12 (three `set -e` truncation traps).

### deploy.sh hardening (Code Reviewer + Codex)
Codex returned 1 CRITICAL, Code Reviewer 4 CRITICAL / 9 DEFENSIVE / 4 COSMETIC. Applied:
- **Guard failed open (both reviewers, independently).** `assert_safe_ctid` used `[ "$ctid" -lt 211 ]`; on an empty or non-numeric value `test` returns **2**, and because it sat in an `if` condition it was exempt from `set -e` — so the condition read false and the guard *returned success*. The triggering values are exactly what a field-order mistake in `CONTAINERS` produces (a container name, a script path). Reproduced failing open, replaced with an exact-string whitelist derived from `CONTAINERS` itself so it cannot drift, then re-verified: 9 malformed/protected inputs refused, 5 valid CTIDs allowed.
- `actual_ip=$(pct exec ... | awk ...)` under `pipefail` killed the whole run and made the `-z` branch written to handle it unreachable → `|| true`.
- One failing container aborted the remaining batch → per-target `rc` capture, `failed` counter, exit 2 on partial failure.
- `destroy`/`reset` now **require an explicit target** (no `all` default — a forgotten argument used to mean "destroy everything", which becomes silent under `CTF_ASSUME_YES=1`); single-target destroy/reset now prompt too; `pct destroy` failure no longer swallowed by `|| true`; `err`/`warn` → stderr; `PROTECTED_IDS` → array; printf no longer counts ANSI bytes toward column width.
- **Codex trace note:** both Codex passes contained `windows sandbox: timed out after 15000ms connecting runner pipe-in` (it can review inlined content but its tool-exec is still broken), so per the dual-review rule its passes are not trusted on their own. Its CRITICAL stands only because it was independently reproduced and independently found by the Code Reviewer. agy was unavailable (needs OAuth).

### SSH
Added the Kali VM public key (`kali@kali`, ed25519, `SHA256:gk3pC+wQ/ridjGkZTKgwrs2U/oZieZHdB27SHhhMUis`) to `/root/.ssh/authorized_keys`. That path is a symlink into pmxcfs (`/etc/pve/priv/authorized_keys`), so it was updated read-modify-write rather than appended; prior file backed up first. Host now carries 6 keys.

---

## 2026-07-21

**Lab 1 rebuilt with a new fault set (v2); Lab 4 "Name Resolution Failure" added (CT 206/207, vmbr3). A fault that passed every check shipped inert — caught only by behavioural testing.**

### Lab 1 v2 — new fault set (ticket NSL-49206)
v1 was solved and its solutions read, so the exercise was spent. v2 deliberately bars `ip addr` / `ip route` / `ip neigh` as primary discovery tools — all three v2 faults are invisible to them:
- **Fault 1 (CT 202)** — nftables `inet plant_filter` drops **ICMP echo-request only** on eth1; TCP untouched, so `nc -vz 10.10.10.20 22` succeeds while `ping` fails. Rules 1–2 accept `iifname eth0` / `ip saddr 192.168.10.0/24` *before* the drop, which is what keeps SSH alive. Found with `nft list ruleset`.
- **Fault 2 (CT 202)** — strict `rp_filter` + an nft-set **fwmark** steering the peer's source into policy table 100 (`10.10.10.10 dev lo`), so ingress is dropped as a martian at the routing decision. Found via `dmesg` martians.
- **Fault 3 (CT 201)** — `tc netem loss 100%` on eth1 egress. netem drops on enqueue, *upstream of the AF_PACKET tap*, so `tcpdump` on A can't even see A's own outbound packets. Found with `tc qdisc show`.
- Persistence via `lab-faults-v2.service`; the decoy `/etc/sysctl.d/60-plant-net.conf` is overridden by `99-zz-plant-hardening.conf`, so fixing the obvious file leaves the box broken after reboot. v1 preserved as `break-v1.sh` + SOLUTIONS.md Appendix A.

### Lab 4 — Name Resolution Failure (ticket NSL-51907)
CT 206 `lab-dns-a` (dnsmasq DNS+DHCP, 10.40.40.10) + CT 207 `lab-dns-b` (DHCP client) on new isolated bridge **vmbr3**. Zone `plant.northstar.example`. Teaches the most misdiagnosed class of field problem — resolution failures presenting as network outages.
- **Fault 1** — dnsmasq bound to `127.0.0.1` **plus** an ingress DROP on port 53. The DROP is load-bearing: without it the kernel returns ICMP port-unreachable and `dig` says *refused*, teaching the wrong lesson. The lab is about **timeout ("nothing answered") vs REFUSED ("answered, said no")**.
- **Fault 2** — stale `/etc/hosts` entry; since `nsswitch.conf` is `files dns`, `getent`/apps get the wrong address while `dig` (which ignores `/etc/hosts`) returns the right one. The "but dig says it's fine" trap.
- **Fault 3** — wrong A record + `local-ttl`/`neg-ttl` 3600 in a separate later-sorting file. dnsmasq re-reads `/etc/hosts` on SIGHUP but **not** its own config, so `systemctl reload` makes a correct fix look failed.
- **DHCP containment (verified, not assumed):** dnsmasq bound only to `127.0.0.1:53`; no `dhcp-range` active under fault 1; `no-dhcp-interface` on eth0/eth1/lo; `nmap` confirms **`67/udp closed`** on the mgmt IP. Client-side, four independent brakes stop the DHCP client installing a default route (incl. the option-121 classless-static-route path) or overwriting `resolv.conf`.

### A fault that passed every check and was still inert
Lab 1 fault 2 originally used an **`iif eth1`** policy rule. It is not consulted by strict RPF: `__fib_validate_source()` builds its own flow with `oif = 0`, so `flowi4_iif` is `LOOPBACK_IFINDEX` and `fib4_rule_match()` can never match an `iif`-keyed rule. The fault did nothing — while `sysctl`, `ip rule show` and `ip route show table 100` all read exactly as intended and the script reported success.
- Caught by the Code Reviewer's kernel-source reasoning, then **confirmed empirically**: `iif` → **0 martians**; nft-set `fwmark` + `src_valid_mark` → **3 martians**.
- The suggested `iptables` mark rule **also silently failed** — `iptables` is not installed in these containers at all, so it no-ops and made the working fix look broken. Only the nft-native mark works.
- **Root lesson:** fault 3 had a *functional* postcondition (attach the qdisc, then prove packets die); fault 2 had only a *configuration* postcondition. That asymmetry is exactly why one shipped broken. A fault that cannot be observed failing is not armed.

### Review + integration fixes
Code Reviewer returned **3 CRITICAL / 7 DEFENSIVE / 6 COSMETIC**; all three CRITICALs fixed: the inert fault 2 (above); an iptables-fallback postcondition grepping `echo-request` when `iptables -S` renders `--icmp-type 8` numerically; and lab 4's `B_FALLBACK_IP=10.40.40.120` sitting **inside** the `.100–.150` DHCP pool despite a comment asserting the opposite (collision risk + it inverted the "did DHCP work?" signal). Moved to `.200`.
- **Ticket drift fixed systemically** — each ticket lived both as a heredoc inside `setup.sh` and as a `.txt`, so rebuilding faults shipped the *previous* ticket. `deploy.sh` now installs the on-disk `.txt` last for every lab; the two can no longer drift.
- `deploy.sh` `faults_live()` still probed v1 signatures, so a correctly-armed v2 lab reported `FIXED`. Now probes `tc qdisc` + `nft`.
- `lab1/setup.sh` (the reset tool) taught to clear v2 residue: nft filter + mangle tables, `rp_filter`, `src_valid_mark`, `ip rule`, table 100, qdisc.
- Host: `sch_netem` loaded + persisted via `/etc/modules-load.d/lab-fae.conf` so fault 3 gets real netem rather than the `pfifo` fallback.
- **Codex was unavailable for the second review pass** — `windows sandbox: timed out after 15000ms connecting runner pipe-in` on every exec (even `Get-Location`), so it could not read the files. Model side is healthy (auth/websocket/reachability green). `codex doctor` went `degraded → 17 ok · 0 warn · 0 fail` after fixing a duplicate agent role name (`Prompt Engineer` declared twice) and restoring the `[projects]` trust entry lost when `config.toml` was zero-filled by NTFS corruption 2026-07-16. This review was therefore **single-sided (Code Reviewer only)** — noted per the dual-review rule.

### Docs
README.md rewritten for lab 1 v2 + a full lab 4 walkthrough (incl. the four `dig` outcomes table — timeout / REFUSED / NXDOMAIN / SERVFAIL — and `getent` vs `dig` as the NSS-vs-DNS test). SOLUTIONS.md likewise, with v1 retained as Appendix A. New agent `custom-linux-networking-fae.md` authored and sharpened with this host's hard-won specifics (Sacred Invariant as Rule 1, PVE rewriting `/etc/network/interfaces` on every start, Tailscale MagicDNS poisoning container DNS, TUN passthrough, verification discipline).

## 2026-07-20

**FAE practice labs built and deployed (CT 201–205). CTF lab decommissioned to free the CTIDs. New isolated bridges vmbr1/vmbr2.**

### What was built
Three re-armable troubleshooting labs for hands-on Linux/networking practice, in `fae/` (repo) → `/root/fae/` (host):
- **lab1 — broken router** (CT 201/202, segment `10.10.10.0/24` on vmbr1): 3 layered faults — `/28` mask mismatch putting the peer outside the subnet, a scoped bogus next-hop via `10.10.10.254` (+ a `/32` so longest-prefix decides deterministically), and a `PERMANENT` poisoned ARP entry. Each found with a different tool (`ip addr` / `ip route` / `ip neigh`).
- **lab2 — tunnel failure** (CT 203/204, OpenVPN static-key over vmbr2): tunnel stays `active (running)` as a deliberate red herring. 3 faults — `ip_forward=0` on the server, deleted far-LAN return route on the client, and an MTU black-hole (`tun-mtu 1500` + `mssfix 0` + `mtu-disc yes` over a 1400 carrier) producing the classic "ping works, transfers hang". Simulated site LANs in network namespaces (`172.16.10.0/24` / `172.16.20.0/24`) so forwarding faults genuinely bite end-to-end.
- **lab3 — raw log playground** (CT 205): 11,016-line `/var/log/syslog`, 4,516-line gzipped `syslog.1.gz`, 2,778-line `auth.log` with 4 failure bursts time-correlated to the NIC-flap windows, 4 error classes in 12 clustered bursts, ~16 malformed lines across 8 types. Logrotate disabled (it would silently destroy the dataset).

### Architecture
- **Dual-homed containers.** `eth0` mgmt on vmbr0 (`192.168.10.201-205`, Tailscale-reachable) is never touched by any fault; `eth1` sits on a new **isolated** bridge (`vmbr1`/`vmbr2`, `bridge-ports none`, no host IP) where all breakage lives. Bridges added via `/etc/network/interfaces.d/lab-bridges` so `vmbr0`'s stanza was never edited.
- **Privileged + `nesting=1`**, with `/dev/net/tun` passthrough on lab2 (smoke-tested before building).
- **Re-arm by snapshot.** `lab_armed` taken post-break; `deploy.sh reset <lab>` rolls back.
- `deploy.sh` guards: `PROTECTED_IDS="100 300 900 901"` + `assert_safe_ctid` at 10 points *inside* the helpers, so a typo'd CTID cannot reach CT 300 or the VM templates.

### Review
Dual review per the standing rule. **Code Reviewer: 10 CRITICAL / 17 DEFENSIVE / 8 COSMETIC. Codex (scoped to deploy.sh + lib/common.sh): 4 CRITICAL / 5 DEFENSIVE.** All applied. Codex's first run was SIGTERM'd at the 900s cap; the retry also failed until `--skip-git-repo-check` was added (this repo is not a git repo — see [[feedback-codex-exec-nongit-repo]]).

Highlights: lab1 was **undeployable** (it aborted on a pre-existing `eth1` stanza, which PVE writes on *every* container start); a rollback backup was being written *inside* the globbed `interfaces.d/`, risking a boot-time parse failure that would have taken `eth0` down; `gen-syslog.sh` would have **destroyed the host's `/var/log/auth.log`** if run from the wrong shell (now guarded by a `/etc/pve/.version` + hostname assertion, verified by running it on Windows and watching it refuse). Codex separately caught that the mgmt guard could false-pass with a *second* default route via `eth1` — it now parses every default and requires exactly one.

### Three bugs only real deployment could find
1. **Tailscale MagicDNS inherited into containers.** `pct create` inherits the host `/etc/resolv.conf`, which Tailscale generates pointing at `100.100.100.100`. Containers aren't on the tailnet → routing fine, DNS dead, `apt` hung indefinitely at 0% CPU. Fixed with explicit `--nameserver 8.8.8.8 1.1.1.1`.
2. **`awk "{print $1}"` with double quotes** (self-inflicted while applying a *cosmetic* `grep -qw`→`-qx` tweak). Bash expanded `$1` (the role arg) before awk saw it, so the netns check never matched and lab2 silently fell back to the degraded dummy path. `bash -n` passes it — syntactically valid, semantically wrong.
3. **`pipefail` inverting `systemctl is-enabled`.** That command exits non-zero for a disabled unit *by design*; piping it into `grep` made a correctly-disabled service report as a failure. Same bug class the reviewers flagged in lab2's mgmt guard — fixing one instance did not fix the class.
4. **Key seeding never worked.** Container-side `setup.sh` read `/root/.ssh/authorized_keys`, which resolves *inside* the container (empty on a fresh build). `deploy.sh` now calls `seed_keys` from the host side automatically; `deploy.sh keys <target>` re-seeds in place.

### Verified on deploy
All 5 containers built, faults armed, `lab_armed` snapshots taken, mgmt path intact on every container (single default via `192.168.10.1 dev eth0`). Symptoms independently reproduced: A→B ping **fails**, site-to-site **fails**, both OpenVPN units report `active`. 4 SSH keys seeded to `fae` (0600, `fae`-owned) on all five.

### CTF lab decommissioned
CT 201–205 destroyed to free the CTIDs/IPs. Fully rebuildable — `ctf/` (repo) and `/root/ctf/` (host) intact: `bash /root/ctf/deploy.sh deploy all`. `ctf-lab.md` marked DECOMMISSIONED with a CTID-conflict warning. Also corrected pre-existing drift: CLAUDE.md listed four files in `plans/` when only `windows-backup-runbook.md` exists.

## 2026-07-04

**Full health diagnostic (clean) + authorized pentest (STRONG posture) + hardening pass. Logged a Jun 19 OWC enclosure re-enumeration event, confirmed the Jun 4 auto-update landed, and moved the auto-update timer to a twice-monthly cadence.**

### Diagnostic sweep (read-only)
- Full host diagnostic run via SSH: compute, storage, SMART, backups, services, network, journal. **Verdict: healthy.** Uptime 30d, load 0.21, CPU pkg 56°C / internal NVMe 40.9–51.9°C, RAM 2.2G/32G used (swap idle), 0 failed systemd units, fail2ban both jails 0 banned. Storage headroom huge: `local-lvm` thin 5.68%, `sata-vmstorage` 0.82%, pve-root 15%. Backups fresh (restic + Veeam both 0h old). CT 300 web-server up; all other guests in expected stopped states.
- **Confirmed Jun 4 02:31 bi-monthly auto-update fired successfully** (first `proxmox-monthly-update.timer` run): PVE 9.2.2 → **9.2.3**, running kernel 7.0.2-6-pve → **7.0.6-2-pve**, rebooted clean. Updated CLAUDE.md Server line to match (was stale at 9.2.2 / 7.0.2-6). Next timer fire: Thu 2026-08-06 02:36 CDT.
- 37 apt updates pending at diagnostic time (grew to 39 by the pentest, incl. `-security` OpenSSL/libssh2/urllib3 + QEMU). Auto-update cadence was changed later this same day (see the hardening pass below) to clear them sooner.

### Jun 19 07:55:54 — OWC Express 4M2 full USB re-enumeration (one-off, no data loss)
- All three enclosure drives (sdb/sdc/sdd) dropped **simultaneously** with EXT4 journal aborts + `device offline error` / `JBD2: I/O error`, then the `1e91:de83 OWC Express 4M2` bridge re-enumerated on the USB bus **8 seconds later** (07:56:02) and all three re-attached (`usb 2-4: New USB device found ... Product: Express 4M2`).
- **Diagnosis: enclosure/USB-link/power blip, NOT drive failure** — a single drive dying can't take its two neighbors offline in the same instant, and the recovery was a whole-bridge re-enumeration. `x-systemd.automount,nofail` self-healed the mounts; backups have run fresh every 30 min since.
- **One-off**: only such event in the entire journal history, zero recurrence in the 15 days since. Consistent with the 2026-05-22 stress-test pass (0 bridge resets). If it recurs, suspect USB-C cable/port or enclosure PSU before the drives.
- **Known monitoring gap surfaced**: the OWC bridge does not pass SMART through even with `-d sat` (`unsupported scsi opcode`), so sdb/sdc/sdd have no wear/reallocation telemetry. `backup-health-check.sh`'s USB-reset/IO-event watch is the compensating control (and is what would have flagged this event had it been inside the 24h window). Internal NVMe (3% used) + SATA SSD (SMART PASSED) unaffected.

### Authorized penetration test — verdict: STRONG (well-hardened)
- Scope: Proxmox host `192.168.10.147` + CT 300 internal web server `192.168.10.220`. Intensity: recon + enum + authenticated read-only hardening audit (no brute-force, no exploitation). Ran cleanly during a live Veeam backup — no interference, no fail2ban bans. Conducted via the Penetration Tester agent; every finding re-verified against the host before acceptance.
- **0 Critical, 0 High.** Positive controls confirmed: SMB firewalled to `lo`+`tailscale0`, CT 300 nginx binds localhost-only behind an outbound Cloudflare Tunnel (zero network web surface), SSH key-only w/ post-quantum KEX, TLS 1.2/1.3-only on 8006, clean accounts/filesystem, fail2ban active.
- Findings: **M1** no web-UI 2FA (single-factor root@pam on 8006); **M2** 39 pending updates incl. `-security` OpenSSL/QEMU; **M3** `claude-mcp` API token has privsep disabled (root-equivalent) + MCP `exec_command` = remote root; **L1** weak SSH MACs offered (hmac-sha1/umac-64); **L2** pve-firewall disabled + SPICE 3128 exposed beyond intent; **L3** procmail SUID+SGID root (legacy); **L4** web UI missing security headers.

### Hardening pass (remediation)
- **Auto-update cadence: bi-monthly → semi-monthly.** `proxmox-monthly-update.timer` OnCalendar `Thu *-2,4,6,8,10,12-1..7` → `*-*-06,20 02:30:00` (6th & 20th of every month; 6/yr → 24/yr) to cut the M2 patch-latency window. Code-Reviewed (clean, deploy-ready) before deploy. Next fire **Mon 2026-07-06 02:36 CDT**. Unit filename left as `proxmox-monthly-update.*` (now a mild misnomer — rename would cascade across docs/paths for no functional gain).
  - **Gotcha logged**: `daemon-reload` after the schedule change triggered an immediate `Persistent=true` catch-up run (the new schedule's Jun 20 occurrence post-dated the last recorded Jun 4 run, so systemd saw a "missed" elapse). The pre-flight gate correctly aborted it at the active-SMB check — no snapshots, no apt — and the failed unit state was `reset-failed`. See [[feedback-systemd-persistent-timer-catchup]].
- **L1** — sshd MACs restricted to strong ETM set (`hmac-sha2-512/256-etm`, `umac-128-etm`) via new drop-in `/etc/ssh/sshd_config.d/10-hardening.conf`; validated with `sshd -t`, reloaded (not restarted). Verified effective.
- **L2** — `spiceproxy.service` `disable --now`; port 3128 no longer listening. SSH 22 + web UI 8006 confirmed intact. noVNC console (via 8006) unaffected.
- **L3** — stripped SUID+SGID off `/usr/bin/procmail` (`-rwsr-sr-x` → `-rwxr-xr-x`).
- **M3a (token) — DONE.** (1) Local `.env` ACL locked to `Gavin` + `SYSTEM` only via `icacls /inheritance:r` — removed a `CodexSandboxUsers:(RX)` read grant. (2) **Rotated + de-privileged the API token**: mapped all 18 MCP tools → 14 use the REST token (need only `VM.Audit VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback Sys.Audit Datastore.Audit`), 4 use root SSH. Created custom role `ClaudeMCP` with exactly those 6 privs; re-minted the token with **privsep 1** (was 0 = root-equivalent), preserved the existing ~2026-10-16 expiry (the naive rotate would have removed it → never-expire); granted `ClaudeMCP @ /`. New secret written to `.env` (never printed). Verified: token authenticates + lists VMs (VM.Audit OK), and `/access/permissions` returns exactly the 6 privs at `/` — root inheritance gone. **Any Claude Code session with the Proxmox MCP loaded must restart** to pick up the new secret (old secret is now invalid).
  - **M3b (SSH root path) — OPEN / tracked separately.** The MCP server's `exec_command` + 3 docker tools hold passwordless root SSH to the host — a separate credential (SSH key) that no ACL scopes, and the larger root-equiv blast radius. Mitigation is a design change (restricted shell / command allowlist / dedicated non-root sudo user for docker), not a quick tweak. Also still open: shortening the token expiry further and locking the Pi-side secrets — deferred to a planned window.
- **M1** — TOTP 2FA enabled for `root@pam` via web UI (Datacenter → Permissions → Two Factor). **Verified** via `pvesh get /access/tfa`: two factors registered — `totp` (desc `root-phone`) + `recovery` keys; not locked. API tokens bypass 2FA by design, so MCP/OpenClaw automation unaffected.
- **L4** — **not applied by design.** pveproxy (8006) has no supported custom-header mechanism; the only paths are a reverse proxy or a Perl source patch (which the pending pve-manager 9.2.4 update would overwrite). Residual clickjacking risk on a LAN-only admin UI is negligible once access is restricted + 2FA is on — accepted.

## 2026-05-23

**Proxmox 9.1.1 → 9.2.2 upgrade; backup-health-check.sh patched; bi-monthly auto-update automation deployed.**

### Host upgrade
- Manual `apt full-upgrade` from PVE 9.1.1 / kernel 6.17.2-1-pve → PVE 9.2.2 / kernel 7.0.2-6-pve. 169 packages. Pre-flight snapshots of CT 100/201–205/300 + VM 100; `/etc/{pve,network,samba,grub,nftables.d}` backed up to `/root/preupgrade-2026-05-23/`. `--force-confold --force-confdef` preserved sshd_config, smb.conf, grub.cmdline (`usb-storage.quirks=174c:0c17:u` carried over — dead code on OWC, harmless).
- New kernels installed alongside running 6.17.2: `proxmox-kernel-6.17.13-11` (latest 6.17 series) + `proxmox-kernel-7.0.2-6` (new 9.2 default). GRUB picks 7.0.2-6 by default; 6.17.13-11 available under Advanced options as fallback.
- **Repo correction**: discovered the host had been on the enterprise repos (`enterprise.proxmox.com`) since install — 7+ weeks without PVE package updates (only Debian base/security). Disabled `pve-enterprise.sources` and `ceph.sources` (renamed `.disabled`), added `pve-no-subscription.sources`. Ceph repo left disabled (single-node, no Ceph in use).
- Post-reboot: CT 300 + Tailscale + Samba + nftables `samba_lock` + backup-health-check.timer + dfwagentops.com all back automatically. HTTP 200 in 98ms.

### `backup-health-check.sh` bug fixes (surfaced by the upgrade)
- **Bug 1 — autofs+ext4 stacking**: post-reboot run failed with `fstype='autofs\next4'`. Either kernel 7.0 or util-linux/systemd changed how stacked `x-systemd.automount`+ext4 mounts are reported. Fix: `findmnt -t ext4 ... | head -1` filters to ext4 entries and inoculates against future multi-line-output regressions. (Code Reviewer CRITICAL caught the `| head -1` defensive guard.)
- **Bug 2 — find/sort/head pipefail masking timeout**: `newest=$(timeout 60 find ... | sort -rn | head -1)` could false-pass after `timeout` killed `find` mid-scan. With `pipefail`, `sort` returns SIGPIPE 141 when `head -1` closes early, mass overwriting find's 124 timeout exit. Restructured to capture `find` exit status separately, then sort/head on already-captured data. (Codex caught.)
- Old script backed up to `/usr/local/sbin/backup-health-check.sh.bak-20260523`. Post-fix re-run: EXIT=0 clean.

### `proxmox-monthly-update.sh` — bi-monthly automated upgrade
- New script `scripts/proxmox-monthly-update.sh` (355 lines) deployed to `/usr/local/sbin/`.
- Phases: (1) pre-flight — /boot >500MB, /var >5GB, backup-health-check passes, no vzdump (via flock on `/var/run/vzdump.lock`), no active SMB clients (smbstatus data-row regex), no in-progress Proxmox cluster tasks; (2) snapshot all CTs/VMs (skip templates) as `auto_update_YYYY_MM` + `/etc` backup to `/root/preupgrade-DATE/`; (3) `apt full-upgrade -y --force-confold --force-confdef` (no internal `timeout` wrapper — systemd unit owns the cap); (4) reboot **only if** running kernel ≠ latest installed `proxmox-kernel-*-pve-signed` (kernel-version-compare via `dpkg-query | sort -V`, since `update-notifier-common` is NOT installed on stock Proxmox — `/var/run/reboot-required` would never be created); (5) cleanup `auto_update_*` snapshots older than 60 days, skipped if reboot pending.
- `--dry-run` mode runs pre-flight + `apt update` + `apt list --upgradable` without snapshots or upgrades.
- Reviews: Code Reviewer (2 CRITICAL + 4 DEFENSIVE — applied PIPESTATUS branching, vzdump flock check, kernel-version reboot detection, robust smbstatus regex) + Codex (3 more CRITICAL + 5 DEFENSIVE — applied pct/qm/smbstatus/pvesh fail-closed wrappers, shutdown PIPESTATUS, dpkg-query ii filter, apt list rc check, removed internal apt timeout in favor of systemd's).
- systemd unit `proxmox-monthly-update.service` (`Type=oneshot`, `TimeoutStartSec=5400`, `KillSignal=SIGINT`, `TimeoutStopSec=1800`, `AssertPathExists`/`AssertFileIsExecutable` so a missing script fails LOUDLY, `After=network-online.target tailscaled smbd pve-cluster`).
- systemd timer `proxmox-monthly-update.timer` — `OnCalendar=Thu *-2,4,6,8,10,12-1..7 02:30:00 RandomizedDelaySec=600 Persistent=true`. **First fire: Thu 2026-06-04 02:30:33 CDT**, then Aug 6, Oct 1, Dec 3, Feb 4, Apr 1...
- Schedule chosen 02:30 not 02:00 to dodge top-of-hour restic backups — verified the gate trips on an active restic SMB session during live-test at 11:12 CDT today (exactly the failure class the gate is designed to catch).
- Unit files committed at `systemd/proxmox-monthly-update.{service,timer}`. Reports to `/var/log/proxmox-monthly-update.log` + journal (`journalctl -u proxmox-monthly-update`).

## 2026-05-22

**OWC Express 4M2 enclosure validated and brought into service; backups migrated off internal SATA.**

- Replacement enclosure connected: **OWC Express 4M2** — 4-bay NVMe, USB-C 3.2 Gen 2 (USB ID `1e91:de83`). The 3 NVMe sticks from the dead ASMedia unit moved into it; 4th bay free.
- Write-verify stress test (`scripts/owc-stress-test.sh`): 30GB sustained write + full readback verified against an in-flight seed checksum. Result: **0 bridge resets, 0 I/O errors**, ~520 MB/s write / ~715 MB/s read. Decisive pass (the ASMedia couldn't survive a 2GB read).
- Test script was Code-Reviewed before running — caught a silent-pass bug (failed verify didn't `exit 1`) and an I/O-error-masking pipeline; both fixed before deployment.
- 3 OWC drives reformatted ext4 with labels `fast-tier` (256GB), `backup-files` (500GB), `backup-images` (512GB).
- fstab USB entries restored to `x-systemd.automount,nofail` (self-heal re-enabled — safe again with a reliable enclosure).
- Migrated off the cramped 200GB internal SATA partition onto the OWC: restic repo (2.7GB) → `/mnt/backup-files/restic/`; full Veeam chain (197GB — 177GB full + 2 incrementals + metadata) → `/mnt/backup-images/Window-Backup/`. Byte-exact verified.
- Samba shares (`backup-files`, `backup-images`) re-pointed to the OWC paths; share names unchanged so Windows configs keep working.
- Capacity constraint resolved — OWC drives have room for a full Veeam chain plus proper retention.
- Repo reorganized: added `scripts/` directory; `owc-stress-test.sh` lives there as a reusable enclosure-validation tool.
- Added `backup-health-check.sh` (Code-Reviewed — caught a critical `findmnt --target` bug that would falsely report a missing drive as healthy) + `backup-health-check.timer` running daily ~09:00. Checks mounts, free space, restic/Veeam freshness, and USB errors; exit codes feed OpenClaw alerting. Verified restic-backup.ps1 already prunes correctly (`forget --keep-* --prune`).

## 2026-05-20

**USB enclosure RMA'd; backups rearchitected to internal SATA.**

- Phase 2 fault-isolation testing (moving drives between bays) confirmed all three NVMe sticks are healthy; the ASMedia ASM246X bridge silicon is intermittently bad across multiple channels — which channel fails varies between sessions. Cannot be trusted in any bay.
- $200 enclosure returned to Amazon (within 30-day window from 2026-04-29 purchase).
- 3 NVMe drives (256GB + 2×512GB) set aside as spares.
- Samba shares (`backup-files`, `backup-images`) re-pointed at internal SATA: `/mnt/pve-backups/windows-backups/{restic,veeam}/` (gavin:gavin 0750). Share names unchanged → Windows cmdkey / Task Scheduler / Veeam `Z:` mapping kept working with zero reconfiguration.
- Restic repo re-initialized fresh (old repo on dead sdc treated as lost; source data intact on Windows).
- Veeam reconfigured with "keep last 1 full" retention — the 200GB partition cannot hold two ~143GB fulls simultaneously.
- USB mountpoints (`/mnt/{backup-files,backup-images,fast-tier}`) kept as empty `noauto` placeholders for future use.

## 2026-05-19

**USB enclosure failures + recovery; UAS quirk added; Veeam image salvaged.**

- sdc threw real I/O errors under read AND write; each error reset the whole USB bridge and wedged the Proxmox host into a D-state cascade (`usb-storage`, `jbd2/sdc-8`, `flush-8:32` stuck; load → 11+). Took the production host down twice in one day.
- Surgical wedge-break procedure proven (works without rebooting the host):
  ```bash
  systemctl stop smbd --no-block
  echo 0 > /sys/bus/usb/devices/2-4/authorized  # D-state clears in seconds
  umount -l /mnt/backup-files /mnt/backup-images /mnt/fast-tier
  ```
- Veeam 143GB bare-metal image salvaged from sdd (healthy drive) → `/mnt/pve-backups/veeam-salvage-20260519/` (byte-exact verified, zero bridge resets during the 143GB read).
- UAS kernel quirk added: `usb-storage.quirks=174c:0c17:u` in `/etc/default/grub` → grub.cfg. Forces the stable BOT driver instead of UAS. Downgraded the failure mode from full-enclosure-drop to reset-loop but did NOT fix the underlying sdc fault.
- Host rebooted to apply quirk; uptime had been 48 days.
- Enclosure defanged: fstab entries → `noauto,nofail`; device deauthorized via sysfs.
- Config backups left at: `/etc/default/grub.bak.preuas-20260519`, `/etc/fstab.bak.{preautomount,prenoauto}-20260519`, `/etc/samba/smb.conf.bak.preinternalmove-20260520`.

## 2026-05-18

**UAS bus drop — 33h silent backup outage.**

- ASMedia bridge dropped the whole enclosure off the USB bus at ~08:44 during a Veeam write.
- Enclosure re-enumerated minutes later but `nofail` fstab provided no auto-remount.
- All three mounts stayed silently unmounted for ~33h; Samba served empty bare mountpoints; hourly restic task failed every run with "unable to open repository".
- Discovered next morning by OpenClaw alerting + investigation.

## 2026-04-29

**Windows backup infrastructure built; external USB-C enclosure added.**

- ASMedia ASM246X 3-bay USB 3.2 Gen 2 NVMe enclosure (USB ID `174c:0c17`) connected with 3 NVMe sticks (256GB + 2× 512GB).
- Intel Optane H10 cache half (27.3GB nvme1n1) — RST metadata wiped, ext4-formatted, mounted as `/mnt/scratch`, registered with Proxmox as `scratch` storage (ISOs/snippets fast tier). `nofail` so a future Optane death won't block boot.
- USB drives formatted ext4 with LABELs (`fast-tier`, `backup-files`, `backup-images`).
- Samba 4.22 installed (Debian 13 package). Standalone server, SMB2+ minimum, signing required, no printers. Two shares (`backup-files`, `backup-images`) owned `gavin:gavin` 0750.
- nftables `samba_lock` table restricts TCP 139/445 to `lo` + `tailscale0` only (LAN-side requests dropped). Persistence via `samba-lock.service` systemd unit.
- `nmbd` disabled (NetBIOS broadcasts don't traverse Tailscale); `samba-ad-dc` disabled (auto-enabled by Debian 13 package, unused in standalone mode).
- Windows side: cmdkey credential added for `100.81.116.89`; restic + Veeam Agent Free configured to write over SMB.

## 2026-04-17

**Security hardening + Tailscale SSH disabled.**

- Tailscale SSH (`--ssh=false`) disabled on Proxmox. Reason: TS SSH + ACL `check` mode required browser re-auth that cron couldn't satisfy, breaking Pi automation jobs. Single auth path (OpenSSH keys) is simpler and more reliable.
- All SSH access now goes through OpenSSH with key auth (Windows, Pi, OpenClaw container).
- CT 300 (dfwagentops.com) hardened: nginx rate limits, `server_tokens off`, slow-loris timeouts, `cloudflared` moved to non-root user, systemd unit hardening (ProtectSystem, NoNewPrivileges, etc.).
- Proxmox `sshd_config`: `PermitRootLogin prohibit-password`, `AllowUsers root`, `PasswordAuthentication no`.

## 2026-04-08

**VM templates built for OpenClaw client deployments.**

- Template 900 (`staging-openclaw-template`, 512MB / 8GB) — temporary client testing.
- Template 901 (`managed-openclaw-template`, 1GB / 20GB) — persistent managed hosting.
- Both built from Debian 12 genericcloud qcow2. Include Docker 29, Node 20 LTS, Tailscale, UFW, QEMU guest agent, OpenClaw starter-kit placeholder, cloud-init.
- Managed template adds unattended-upgrades, Docker log rotation (10MB × 3), system log rotation for OpenClaw logs.
- Management scripts written to `/root/dfwagentops/`: `clone-staging.sh`, `teardown-staging.sh`, `provision-client.sh`, `client-status.sh`.

## 2026-03-31

**Proxmox initial setup; CTF lab deployed.**

- Proxmox VE 9.1.1 installed on HP Laptop 15-dw3xxx (i3-1115G4, 32GB RAM).
- Internal Intel NVMe 477GB partitioned: pve-root (96GB) + pve-data LVM-thin (~349GB, `local-lvm`).
- WD Blue SATA SSD 932GB partitioned: sda1 200GB ext4 → `sata-backups`; sda2 731GB LVM-thin → `sata-vmstorage`.
- 5 LXC containers (201–205) deployed for the CTF lab: web-exploit, linux-privesc, crypto-forensics, network-recon, scoreboard. 13 flags / 2500 points total.
- VM 100 (`ubuntu-target`) preexisting with OWASP Juice Shop in Docker.
- API token `root@pam!claude-mcp` created with `privsep=0`.
- MCP server written in TypeScript (18 tools wrapping the Proxmox REST API + SSH).
