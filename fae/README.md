# FAE Practice Labs

Four deliberately-broken environments for practising hands-on Linux, networking, and troubleshooting — the skills a Field Application Engineer actually gets paid for. Each lab hands you a **field ticket** describing a user complaint, not a fault description. Working out *what* is broken is the exercise.

> **Answers live in [SOLUTIONS.md](SOLUTIONS.md).** It is a separate file on purpose. Don't open it until you've genuinely worked a lab, or you'll burn the one chance that lab has to teach you something.

---

## The labs

| Lab | Containers | Scenario | Faults |
|---|---|---|---|
| **1 — Broken Router** | CT 201 `lab-router-a`, CT 202 `lab-router-b` | Two hosts on an isolated segment can't reach each other | 3 |
| **2 — Tunnel Failure** | CT 203 `lab-vpn-a`, CT 204 `lab-vpn-b` | Site-to-site OpenVPN says "connected", users disagree | 3 |
| **3 — Raw Log Playground** | CT 205 `lab-logs` | 10k+ lines of messy logs to parse | none — it's a build exercise |
| **4 — Name Resolution** | CT 206 `lab-dns-a`, CT 207 `lab-dns-b` | "The network is fine, but the name doesn't work" | 3 |

Labs 1, 2 and 4 have **three layered faults each**. Fixing one reveals the next, and each one is found with a *different tool*. That's deliberate: real outages are rarely one thing, and the instinct to stop at the first thing you find is exactly what this trains out of you.

---

## Getting in

### Network path

Every container is **dual-homed**:

- **`eth0` — management.** `192.168.10.201-207` on `vmbr0`. This is how you get in. **No fault ever touches it.**
- **`eth1` — the lab segment.** On an isolated bridge (`vmbr1`/`vmbr2`/`vmbr3`) with no uplink. **All breakage lives here.**

> Lab 4 runs a **DHCP server**. It is confined to the isolated `vmbr3` bridge and scoped to `eth1` several ways over — it cannot hand out leases on your real LAN. Verified: dnsmasq never binds the management IP, and `67/udp` is closed there.

The Proxmox host advertises `192.168.10.0/24` as a Tailscale subnet route, so from any tailnet device — including your Ubuntu laptop on the road — the lab IPs are directly reachable. No jump host, no port forwarding.

```bash
ssh fae@192.168.10.201     # Lab 1, Container-A
ssh fae@192.168.10.202     # Lab 1, Container-B
ssh fae@192.168.10.203     # Lab 2, Site-A gateway (VPN server)
ssh fae@192.168.10.204     # Lab 2, Site-B gateway (VPN client)
ssh fae@192.168.10.205     # Lab 3, log playground
ssh fae@192.168.10.206     # Lab 4, DNS/DHCP server
ssh fae@192.168.10.207     # Lab 4, client
```

The field ticket is printed as the MOTD when you log in, and saved at `/root/FIELD_TICKET.txt` (Lab 3 uses `/root/LAB_BRIEF.txt`).

### Credentials

- **User:** `fae` — has `sudo`.
- **Password:** `faelab123` (fallback).
- **Keys:** `deploy.sh` seeds `fae`'s `authorized_keys` from the **Proxmox host's** `/root/.ssh/authorized_keys`, so any machine that can already SSH to the host works immediately. (Currently 5 keys: Windows, the Pi, the OpenClaw container, the host itself, and the Ubuntu travel laptop.) If you ever add a key to the host afterwards, run `deploy.sh keys all` to push it into the running containers.
- **No root password is set** — deliberate. `PermitRootLogin prohibit-password` means it would never work over SSH anyway. For root console: `pct enter 201` from the host.

---

## Managing the labs

Run these **on the Proxmox host** (`ssh root@100.81.116.89`):

```bash
bash /root/fae/deploy.sh status              # what's running, snapshot + live fault state
bash /root/fae/deploy.sh reset lab1          # roll back to the armed broken state (lab1|lab2|lab3|lab4|all)
bash /root/fae/deploy.sh reset all           # re-arm everything
bash /root/fae/deploy.sh keys all            # re-seed SSH keys from the host
bash /root/fae/deploy.sh deploy lab2         # rebuild a lab from scratch
bash /root/fae/deploy.sh destroy all         # tear it all down
```

`status` reports **SNAP** (a reset point exists) and **FAULTS** (`armed` / `FIXED`) separately — so it tells you whether you've actually solved a lab, not just whether it was ever set up.

**`reset` is your friend.** It rolls back to a snapshot, so no matter how badly you mangle a box while exploring, you're one command from a clean broken state. Experiment aggressively.

---

## ⚠️ The one rule

**Never reconfigure `eth0`, its address, or the default route.**

That's your only way in. The tickets say the same thing in-fiction ("it becomes a truck roll"). Every fault is scoped to `eth1` or the lab subnets — if you find yourself editing anything on `eth0`, you've wandered off the exercise.

If you do lock yourself out: `pct enter <CTID>` from the Proxmox host gets you a root console, or just `reset` the lab.

---

## How to actually troubleshoot this stuff

The single biggest difference between a junior and a senior on a live call is **method**. Not knowledge — method. Juniors guess and change things. Seniors narrow the fault domain until only one thing can be true.

**Work the layers, bottom-up.** Don't debug OpenVPN before you've proved the two boxes can exchange packets.

1. **Link** — is the interface up? `ip link show eth1`. Look at `state`, and at `mtu`.
2. **Address** — right IP, and crucially the **right prefix**? `ip addr show eth1`. A wrong netmask is invisible unless you actually read the `/nn`.
3. **Neighbour** — is L2 resolving, and to something *sane*? `ip neigh show dev eth1`. A `PERMANENT` entry is never normal on a lab segment.
4. **Route** — what path will this packet actually take? `ip route get <dst>` answers what the kernel will *do*, which beats reading the table and guessing.
5. **Forwarding** — if the box is a gateway, is it allowed to forward? `sysctl net.ipv4.ip_forward`.
6. **Filter** — anything dropping it? `iptables -L -n -v`, `nft list ruleset`.
7. **Application** — only now: `systemctl status`, `journalctl -u <unit>`.

**Prove each layer before moving up.** And after every change, **re-test** — don't assume the fix worked.

### Habits worth building

- **`ping` failing does not mean "the network is down."** ICMP can be filtered while TCP flows fine. Test the actual service too: `nc -vz <host> <port>`.
- **`ping` succeeding does not mean "the network is fine."** A 64-byte probe proves almost nothing about a 1500-byte payload. This one bites people constantly — see Lab 2.
- **"The service is running" is a statement about the service, not the path.** `active (running)` means systemd started a process. It says nothing about whether traffic works.
- **Watch the wire when the config looks right.** `tcpdump -ni eth1 icmp` tells you whether packets leave, arrive, and get answered. If a request arrives and no reply leaves, the problem is on the *receiving* box — that single observation halves your search space.
- **Read errors literally.** `Destination Host Unreachable` (a router telling you it can't deliver) and a silent timeout are completely different diagnoses.

---

## Lab 1 — The Broken Router

**Ticket NSL-49206.** Two plant-floor controllers on an isolated `10.10.10.0/24` segment stopped answering ping overnight. Management access is fine.

```
Container-A  10.10.10.10   (CT 201, ssh fae@192.168.10.201)
Container-B  10.10.10.20   (CT 202, ssh fae@192.168.10.202)
```

> **This is fault set v2.** If you previously solved the netmask/route/ARP version, this is a completely different set — none of `ip addr`, `ip route`, or `ip neigh` will find any of it. That's deliberate.

### Your job
Restore bidirectional connectivity between `10.10.10.10` and `10.10.10.20`, make it survive a reboot, and document root cause.

### Where to start
Log into **both** boxes. Then, before anything else, **stop trusting ping**:

```bash
ping -c3 10.10.10.20              # from A
nc -vz 10.10.10.20 22             # ...and now test TCP to the same host
```

If those two disagree, you have learned more in ten seconds than an hour of staring at `ip addr` would have taught you.

```bash
ip addr show eth1 ; ip route ; ip neigh show dev eth1   # all read PERFECTLY. That's the point.
tc qdisc show dev eth1            # the layer nobody checks
nft list ruleset                  # the filter layer
dmesg -T | tail -40               # the kernel's own complaints
sysctl -a | grep rp_filter
```

### Progressive hints

<details><summary>Hint 1 — everything in `ip` output looks correct and nothing works</summary>

Then the fault is not in addressing, routing, or ARP. Packets can also die **below** those layers (the queueing discipline, on egress) or **beside** them (the firewall, on ingress). Start on **A** with `tc qdisc show dev eth1` and ask what `netem` is doing there.

A tell worth noticing: run `tcpdump -ni eth1 icmp` on A while pinging from A. If you can't even see your *own outbound* packets, the loss is happening below the capture point.
</details>

<details><summary>Hint 2 — I cleared the qdisc; now B can ping A but A still can't ping B</summary>

Progress — that asymmetry is a real clue. A's packets now reach B, so the problem is what B does with them on arrival. B is dropping them *before* any socket sees them, and the kernel says so. Check `dmesg -T` on B and look for the word **martian**.

Then ask what makes a kernel call a packet a martian: it does a **reverse-path check** — "if I had to send a reply to this source, would it go back out the interface it arrived on?" Look at `sysctl -a | grep rp_filter`, then `ip rule show` and `ip route show table 100`.
</details>

<details><summary>Hint 3 — where is that reverse-path answer actually coming from?</summary>

There's a policy routing rule keyed on a firewall **mark**, sending the lookup to a separate table. Find the mark rule with `nft list ruleset` (look for a `mangle`-style table, not the filter one), then follow it: `ip rule show` → `ip route show table 100`.

Also: check `/etc/sysctl.d/`. More than one file has an opinion, and they don't agree. The one that wins is not the one that looks relevant.
</details>

<details><summary>Hint 4 — routing is clean now, TCP works, but ping still fails</summary>

That is the finish line, not a problem. `ping` uses ICMP; `nc`/ssh use TCP. If one works and the other doesn't, something is filtering **by protocol**. `nft list ruleset` on B, and read the rules in order — note which ones come *before* the drop, and why they're there (they're what has been keeping your SSH session alive this whole time).
</details>

### Done when
`ping` succeeds **both directions**, and still succeeds after `reboot` on both containers. Verify with `deploy.sh status` — FAULTS should read `FIXED`.

### Why this matters
Every fault here is invisible to the commands people reach for first. The habit it builds: when addressing and routing read perfectly and traffic still dies, you are looking at the **wrong layer**, not the wrong value. And "ping fails" is a symptom, not a diagnosis — a filtered ICMP with healthy TCP is a very common real-world configuration, sometimes deliberate.

## Lab 2 — The Tunnel Failure

**Ticket NSL-49037.** Site-to-site OpenVPN reports connected. Small tests work. File transfers hang forever.

```
Site-A gateway  10.20.20.10  tunnel 10.99.99.1  LAN 172.16.10.0/24   (CT 203, VPN server)
Site-B gateway  10.20.20.20  tunnel 10.99.99.2  LAN 172.16.20.0/24   (CT 204, VPN client)
```

Each gateway has a simulated site LAN behind it in a network namespace, so traffic between sites is genuinely **forwarded** — which makes forwarding faults actually bite instead of merely looking wrong.

### Your job
Restore real end-to-end usability — sustained transfer of real payloads, not just reachability. Must survive a reboot.

### Where to start
The tunnel is **up**. `systemctl status openvpn@server` will show `active (running)` and tell you nothing. Resist the urge to restart it; the reporter already did, twice.

```bash
systemctl status openvpn@server        # (server) / openvpn@client on B — the red herring
ip addr show tun0                      # tunnel interface + MTU
ping -c3 10.99.99.1                    # tunnel endpoint to endpoint
ip route                               # is the far site's LAN routed at all?
sysctl net.ipv4.ip_forward             # is this gateway allowed to be a gateway?
ping -c3 -M do -s 1400 10.99.99.1      # large packet, don't fragment  <-- the key test
```

### Progressive hints

<details><summary>Hint 1 — The tunnel is up and small pings work. Now what?</summary>

Then don't test with small pings. The complaint is that *large* transfers hang. Reproduce the actual symptom: `ping -M do -s 1400`. `-M do` sets Don't-Fragment, so instead of silently working around a size limit you'll see it fail. Compare against `-s 100`. If small passes and large dies, you've found the shape of the problem.
</details>

<details><summary>Hint 2 — Large packets fail, small ones pass</summary>

That's a path MTU problem. Something along the path can't carry a full-size frame and the packet is being dropped rather than fragmented. Look at MTU on **every** interface in the path on **both** boxes: `ip link show eth1`, `ip link show tun0`. Compare the two ends. Then look at the OpenVPN config for how it's told to size and fragment.
</details>

<details><summary>Hint 3 — Fixed MTU, tunnel endpoints work, but the site LANs still can't reach each other</summary>

Endpoint-to-endpoint is a different test than LAN-to-LAN. From a site host you're asking the gateway to *forward* between `tun0` and the LAN side. Two independent things must be true: the box must be permitted to forward, and it must know a route to the far LAN. Check both, on both gateways — they are not both broken in the same place.
</details>

<details><summary>Hint 4 — Where do I test from?</summary>

The site hosts live in network namespaces:
```bash
ip netns list
ip netns exec site-a ping -c3 172.16.20.100     # from A's LAN to B's LAN
ip netns exec site-a ip route
```
</details>

### Done when
From Site-A's namespace you can reach Site-B's host **and** push a large payload without stalling:
```bash
ip netns exec site-a ping -c3 -M do -s 1400 172.16.20.100
```
Then reboot both and confirm it holds.

### Why this matters
"Ping works but transfers hang" is one of the highest-value patterns you can learn to recognise on sight — it is almost always MTU/PMTU, and it's invisible to every tool that only sends small packets. The `ip_forward` fault is a top-3 real-world VPN misconfiguration, and it's genuinely nasty because every routing table you inspect looks correct.

---

## Lab 3 — The Raw Log Playground

Not a break/fix. A **build** exercise: write a parser from scratch.

```
ssh fae@192.168.10.205
```

### What's there
- `/var/log/syslog` — 11,000+ chronologically ordered lines
- `/var/log/syslog.1.gz` — ~4,500 older rotated lines, gzipped
- `/var/log/auth.log` — sshd auth records

### Your job
Write a Python script (no external libraries — that's the point) that:

1. Parses `/var/log/syslog`, including the rotated `.gz`.
2. Identifies and classifies the **error categories** hiding in the noise.
3. Counts each, and reports **when** they happened — not just totals.
4. **Correlates** the bursts against `/var/log/auth.log`.
5. Survives the malformed lines without crashing.

### What makes this non-trivial
- **The errors are clustered, not scattered.** `grep -c` gives you a number; bucketing by time gives you *episodes*. The episodes are the story.
- **Timestamps are the hard part.** Syslog format is `Mon DD HH:MM:SS` — no year, and the day is **space-padded** (`Jul  4`, two spaces). Naive `line.split()` breaks on exactly this. There's your first bug.
- **The data is dirty on purpose.** Garbage timestamps, truncated lines, missing process fields, stray control characters. Real logs are like this. A parser that crashes on line 8,000 is worthless.
- **Rotation matters.** The `.gz` holds *older* data. Handle it (`gzip` module) and get the ordering right.
- **Cross-file correlation is the payoff.** One error class lines up in time with auth activity. Find it and you've reconstructed an incident rather than counted strings.

### Suggested progression
1. Read the file, count lines. (Watch the encoding — those control characters.)
2. Parse one line into timestamp / host / process / message.
3. Run it over all 11k. Count how many fail to parse — then handle them.
4. Group messages into categories. Let the data tell you the categories; don't assume.
5. Bucket by hour. Print a histogram. **The episodes should jump out.**
6. Do the same for `auth.log`. Compare the hot windows.
7. Fold in `syslog.1.gz`.

### Useful before you script
```bash
wc -l /var/log/syslog
awk '{print $5}' /var/log/syslog | sort | uniq -c | sort -rn | head -20   # process frequency
zcat /var/log/syslog.1.gz | head
```

### Optional: a moving target
```bash
sudo systemctl enable --now log-trickle     # appends a line every few seconds
```
Then practise a streaming parser against `tail -f`. Disabled by default.

### Done when
Your script reports each error class with counts and time windows, names the correlated window across both files, and processes every line without an unhandled exception.

---

## Lab 4 — The Name Resolution Failure

**Ticket NSL-51907.** The operator terminal can't reach the plant controller **by name**. IT insists the network is fine. Using the IP address directly works.

```
lab-dns-a  10.40.40.10   DNS + DHCP server  (CT 206, ssh fae@192.168.10.206)
lab-dns-b  DHCP client   operator terminal  (CT 207, ssh fae@192.168.10.207)
Zone: plant.northstar.example
```

### Your job
Make names resolve to the addresses the as-built documentation says they should, for the ordinary tools the operators actually use. Must survive a reboot.

### The one idea this lab is built around
`dig` is **not** a test of what your application will do. `dig` talks to DNS directly. Your application goes through **NSS** (`/etc/nsswitch.conf`), which checks `/etc/hosts` *first*. When those two disagree, you have found something — and `getent hosts` is the tool that tells you what the application will actually get.

Learn to read the four `dig` outcomes; they point at completely different layers:

| `dig` says | Meaning |
|---|---|
| `connection timed out` | **Nothing answered** — server down, not listening, or filtered |
| `status: REFUSED` | Something answered and **said no** — it's up, policy rejected you |
| `status: NXDOMAIN` | Answered authoritatively: **that name doesn't exist** |
| `status: SERVFAIL` | It tried and **failed** — broken upstream/DNSSEC |

### Where to start
```bash
# on the client (CT 207)
ping -c2 controller-a.plant.northstar.example   # fails
ping -c2 10.40.40.10                            # works -> NOT a connectivity problem
dig @10.40.40.10 controller-a.plant.northstar.example
getent hosts hmi.plant.northstar.example        # what apps actually get
dig +short hmi.plant.northstar.example          # what DNS actually says
cat /etc/resolv.conf ; grep hosts: /etc/nsswitch.conf
```
```bash
# on the server (CT 206)
ss -ulnp | grep dnsmasq        # what is it ACTUALLY bound to?
systemctl status dnsmasq
ls /etc/dnsmasq.d/             # read them in sort order — later files win
```

### Progressive hints

<details><summary>Hint 1 — the name fails but the IP works</summary>

Then stop debugging the network; you have already proved packets flow. The failure is in *resolution*. There are only three places it can be: the resolver you're asking, the answer it gives, or something on the client that intercepts the lookup before DNS is ever consulted.

Start by finding out whether you're getting an **answer** or **silence** — run `dig` and read which of the four outcomes above you got. That single word tells you which of the three to look at.
</details>

<details><summary>Hint 2 — dig just times out</summary>

A timeout means *nothing answered*. Not "answered no" — nothing. So either the query isn't arriving, or the server isn't listening where you're asking.

Get on the server and ask the kernel, not the config: `ss -ulnp | grep dnsmasq`. Compare what it's bound to against the address the client is querying. Then check whether anything is filtering port 53 on the way in.
</details>

<details><summary>Hint 3 — the server answers now, but one host still goes to the wrong address</summary>

Compare these two on the client, carefully:
```bash
getent hosts hmi.plant.northstar.example
dig +short hmi.plant.northstar.example
```
If they disagree, DNS is not the thing lying to your application. Read `/etc/nsswitch.conf` and note the **order** of `files` and `dns`, then look at what's in `/etc/hosts`.
</details>

<details><summary>Hint 4 — I fixed the record but dig still returns the old address</summary>

Two possibilities, and you should check both. First: is the value you edited the one actually being served? Files in `/etc/dnsmasq.d/` are read in sort order and later ones win — look at *all* of them, not the one with the obvious name.

Second: look at the **TTL** in the `dig` output. If it's counting down from something absurd, you're being served from cache. And note this dnsmasq-specific trap — it re-reads `/etc/hosts` on SIGHUP but **not** its own config files, so `systemctl reload` will make a correct fix look like it failed. Use `restart`.
</details>

### Done when
```bash
dig @10.40.40.10 controller-a.plant.northstar.example +short   # correct address
getent hosts hmi.plant.northstar.example                        # agrees with dig
ping -c2 controller-a.plant.northstar.example                   # works by name
ip -4 addr show eth1                                            # still a .100-.150 DHCP lease
# then reboot both and confirm it holds
```

### Why this matters
Name resolution failures are the most misdiagnosed class of field problem, because they present as network outages — and teams burn hours on packet captures for something that was never a packet problem. The reflex worth building is one line long: **when a name fails, immediately try the IP.** If the IP works, stop looking at the network.

---

## Command cheat sheet

```bash
# Interfaces & addresses
ip -br link                       # brief: state of every interface
ip -br addr                       # brief: addresses
ip link show eth1                 # MTU + state
ip addr show eth1                 # address + PREFIX (read the /nn!)

# Neighbours (L2)
ip neigh show dev eth1            # ARP table; watch for PERMANENT
ip neigh flush dev eth1           # clear it

# Routing
ip route                          # the table
ip route get 10.10.10.20          # the DECISION the kernel makes — better than reading
ip -4 route show default          # your lifeline. Should be ONE, via 192.168.10.1, dev eth0

# Forwarding & filtering
sysctl net.ipv4.ip_forward
iptables -L -n -v ; nft list ruleset

# Reachability
ping -c3 <ip>
ping -c3 -M do -s 1400 <ip>       # large + Don't Fragment — the MTU test
nc -vz <ip> <port>                # TCP reachability when ICMP lies
tracepath <ip>                    # discovers path MTU
mtr -n <ip>

# Packet capture
tcpdump -ni eth1 icmp
tcpdump -ni eth1 host 10.10.10.20 -vv

# Namespaces (Lab 2)
ip netns list
ip netns exec site-a <command>

# Services
systemctl status openvpn@server
journalctl -u openvpn@server -n 50 --no-pager
```

---

## If a lab itself misbehaves

```bash
# on the Proxmox host
bash /root/fae/deploy.sh status          # includes a mgmt-path health column
bash /root/fae/deploy.sh reset lab1      # clean broken state
bash /root/fae/deploy.sh deploy lab1     # full rebuild if reset isn't enough
pct enter 201                            # root console, bypasses SSH entirely
```

Locked yourself out of a container? That's what `pct enter` and `reset` are for. It's a lab — breaking it is free.
