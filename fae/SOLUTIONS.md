# SOLUTIONS — spoilers ahead

> ## 🛑 STOP
>
> This file contains the complete answers. Each lab teaches you exactly once — reading this first spends that for nothing.
>
> If you're stuck, use the **progressive hints in [README.md](README.md)** instead. They narrow the search without handing over the answer. Come back here only to check your work, or to read the *why* after you've solved it.

---

# Lab 1 — The Broken Router (v2)

> Ticket **NSL-49206**. This is the *second* fault set for lab 1. The original three faults
> (`/28` netmask, bogus next-hop, poisoned ARP) are preserved as **Appendix A** at the bottom
> of this file, and can be re-armed with `break-v1.sh` if you want to redo them.

## The three faults

| # | Where | Fault | Found with |
|---|---|---|---|
| 1 | CT 202 (B) | nftables rule dropping **ICMP echo-request only** on eth1 — TCP untouched | `nft list ruleset` |
| 2 | CT 202 (B) | Strict `rp_filter` + an nft-set **fwmark** steering A's source into policy table 100 (`10.10.10.10 dev lo`) | `dmesg` martians + `sysctl` |
| 3 | CT 201 (A) | `tc` netem qdisc discarding **100% of egress** on eth1 | `tc qdisc show` |

Deliberately, **none** of `ip addr` / `ip route` / `ip neigh` finds any of these — those were v1's tools. Persistence is `/usr/local/sbin/lab-faults-v2.sh` + `lab-faults-v2.service`, so a reboot won't quietly fix it.

## Discovery order (each fix reveals the next)

**Stage 1 — nothing works in either direction.** A transmits nothing at all (fault 3), so both directions look dead.
**Stage 2 — after clearing fault 3**, B→A ping works but A→B still fails. A's packets now arrive at B and are dropped at the *routing decision* (fault 2), logging `martian source` in B's ring buffer.
**Stage 3 — after fixing fault 2**, `nc -vz 10.10.10.20 22` from A **succeeds** while `ping` still fails. That is the payoff: ICMP is filtered, TCP is not (fault 1).

## Fault 3 — the invisible qdisc

**What's wrong.** `tc qdisc ... root netem loss 100%` on A's eth1. Every address, route, and neighbour entry reads perfectly; packets are discarded on enqueue — *upstream of the AF_PACKET tap*, so `tcpdump` on A does not even show A's own outbound packets. That detail is the tell: if your own capture can't see your own transmissions, the loss is below the capture point.

**Detect / fix (CT 201):**
```bash
tc qdisc show dev eth1          # 'qdisc netem ... loss 100%'
tc -s qdisc show dev eth1       # dropped counter climbing
tc qdisc del dev eth1 root
```

## Fault 2 — strict reverse-path filtering

**What's wrong.** `rp_filter=1` (strict) on `all` and `eth1`. An nft `prerouting` rule marks packets from `10.10.10.10` with `0x64`; an `ip rule` keys on that **fwmark** and sends the lookup to table 100, which says `10.10.10.10 dev lo`. The reverse-path lookup therefore resolves to `lo`, not `eth1`, so the kernel drops the packet as a martian *before* any firewall or socket sees it.

**Why fwmark and not `iif`:** strict RPF calls `__fib_validate_source()`, which builds its own flow with `oif = 0` — so `flowi4_iif` is `LOOPBACK_IFINDEX`, and an `iif`-keyed rule **can never match**. It does honour `skb->mark` when `src_valid_mark=1`. (The first build of this lab used `iif` and the fault was completely inert while every config check passed — caught only by testing for the martian log.)

**Detect:**
```bash
dmesg -T | grep -i martian            # the smoking gun
sysctl -a | grep -E 'rp_filter|src_valid_mark'
ip rule show                          # pref 100 ... fwmark 0x64 lookup 100
ip route show table 100
nft list ruleset                      # the mark rule in table 'lab_mangle'
```
> `ip route get 10.10.10.10 from 10.10.10.20 iif eth1` is **not** a valid test — the explicit `iif` populates `flowi4_iif`, which the real Reverse Path Forwarding (RPF) path never does. It will show the poisoned result even when the fault is inert.

**Fix (CT 202):**
```bash
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.eth1.rp_filter=0
ip rule del pref 100
ip route flush table 100
nft delete table ip lab_mangle
rm -f /etc/sysctl.d/99-zz-plant-hardening.conf     # the one that actually wins
```
**The non-obvious-file trap:** `/etc/sysctl.d/60-plant-net.conf` looks like the culprit and sets the knobs to `0`, but `99-zz-plant-hardening.conf` sorts later and overrides it. Fix only the obvious file and the box comes back broken after a reboot.

## Fault 1 — ICMP filtered, TCP is not

**What's wrong.** nft table `inet plant_filter`, chain `plant_in` (hook input). Rules 1–2 unconditionally accept `iifname eth0` and `ip saddr 192.168.10.0/24` — that is what keeps your SSH alive. Rule 3 drops `icmp type echo-request` arriving on eth1 from the lab subnet. TCP is never touched, which is why the night-shift file copy in the ticket succeeded.

**Detect:**
```bash
ping 10.10.10.20                # fails
nc -vz 10.10.10.20 22           # SUCCEEDS  <-- the whole lesson
nft list ruleset
nft list ruleset | grep -A5 counter    # drop counter climbing
```

**Fix (CT 202):**
```bash
nft delete table inet plant_filter
```

## Verify
```bash
ping -c3 10.10.10.20    # from A
ping -c3 10.10.10.10    # from B
# then reboot BOTH and repeat — the persistence unit must be gone:
systemctl disable --now lab-faults-v2.service
rm -f /usr/local/sbin/lab-faults-v2.sh
```
On the host: `bash /root/fae/deploy.sh status` → FAULTS should read `FIXED`.

## Root cause, written up
> Three independent faults on the `10.10.10.0/24` plant segment, none of them visible in addressing, routing, or neighbour state. CT 201 carried a netem qdisc discarding 100% of egress on `eth1`. CT 202 had strict reverse-path filtering enabled, combined with a firewall mark steering the peer's source address into a policy routing table that resolved it to `lo`, causing ingress packets to be dropped as martians at the routing decision. CT 202 additionally filtered ICMP echo-request on the lab interface while leaving TCP unaffected, which is why file transfers succeeded while ping did not. Management interfaces were not involved at any point.

## Why this set teaches something v1 did not
v1 was three *configuration* faults, all visible in `ip` output. v2 is three faults that are all invisible to `ip` — they live in the qdisc layer, the routing-decision layer, and the filter layer. The habit it builds: when addressing and routing read perfectly and traffic still dies, you are looking at the wrong layer, not the wrong value.

---

# Lab 2 — The Tunnel Failure

## The three faults

| # | Where | Fault | Found with |
|---|---|---|---|
| 1 | CT 203 (A, server) | `net.ipv4.ip_forward = 0` | `sysctl` |
| 2 | CT 204 (B, client) | Route to the far site LAN deleted | `ip route` |
| 3 | Both | MTU black-hole: `tun-mtu 1500`, `mssfix 0`, `mtu-disc yes`, carrier MTU 1400 on B | `ip link`, `ping -M do -s` |

The tunnel stays `active (running)` throughout. That's the trap: the control plane is healthy and says nothing about the data plane.

## Fault 3 first — the MTU black-hole

Take this one first; it's the one the ticket actually describes.

**What's wrong.** `setup.sh` builds a sane relationship: carrier (`eth1`) MTU **1500**, `tun-mtu` **1300**, `mssfix 1250` — the encapsulated packet fits inside the carrier with headroom. `break.sh` inverts it:

- `tun-mtu 1500` — the tunnel now claims a full-size MTU
- carrier `eth1` MTU **1400** on B — but the underlying link can no longer carry it
- `mssfix 0` — disables TCP MSS clamping, so TCP stops negotiating around it
- `mtu-disc yes` — sets DF on the outer datagram, so the kernel **drops** oversized packets instead of fragmenting

That last one is what makes it a true black-hole rather than "a bit slow." Small packets fit and sail through; large ones are silently discarded with no ICMP getting back. Hence: ping fine, `scp` hangs forever.

**Detect:**
```bash
ping -c3 -s 100  -M do 10.99.99.1       # passes
ping -c3 -s 1400 -M do 10.99.99.1       # fails  <-- the whole diagnosis
ip link show eth1                        # mtu 1400 on B, 1500 on A — mismatch
grep -E 'tun-mtu|mssfix|mtu-disc' /etc/openvpn/*.conf
tracepath 10.99.99.1
```

**Fix (both containers):**
```bash
# restore the carrier MTU on B (CT 204)
ip link set eth1 mtu 1500
echo 1500 > /etc/lab-vpn/eth1.mtu        # persisted value read by lab-netprep

# fix the OpenVPN config on BOTH
sed -i 's/^tun-mtu .*/tun-mtu 1300/'   /etc/openvpn/*.conf
sed -i 's/^mssfix .*/mssfix 1250/'     /etc/openvpn/*.conf
sed -i '/^mtu-disc /d'                 /etc/openvpn/*.conf

systemctl restart openvpn@server         # on A
systemctl restart openvpn@client         # on B
```

## Fault 1 — forwarding disabled

**What's wrong.** CT 203 has `net.ipv4.ip_forward = 0`, persisted in `/etc/sysctl.d/99-zz-lab-tuning.conf`. Traffic from a site host reaches the gateway and is dropped rather than passed between `tun0` and the LAN side.

The filename is deliberate: it sorts **after** `99-lab-vpn.conf`, so the fault wins on boot. Fixing the wrong file leaves it broken after a reboot — a genuinely realistic trap.

**Detect:**
```bash
sysctl net.ipv4.ip_forward               # 0
cat /proc/sys/net/ipv4/ip_forward
grep -rn ip_forward /etc/sysctl.d/ /etc/sysctl.conf
```

**Fix (CT 203):**
```bash
rm -f /etc/sysctl.d/99-zz-lab-tuning.conf
sysctl -w net.ipv4.ip_forward=1
sysctl --system | grep ip_forward
```
Endpoint-to-endpoint ping works even with forwarding off — the gateway is the *destination* there, not a router. Only LAN-to-LAN traffic exposes it. Test at the right layer.

## Fault 2 — the missing return route

**What's wrong.** CT 204's route to Site-A's LAN (`172.16.10.0/24`) over the tunnel was deleted. Traffic reaches Site-A and Site-A can reply, but B has no path back — classic one-way, and easy to misread as a Site-A problem.

**Detect:**
```bash
ip route                                 # on B — no 172.16.10.0/24
ip route get 172.16.10.100
```

**Fix (CT 204):**
```bash
ip route add 172.16.10.0/24 via 10.99.99.1 dev tun0
```
For persistence add a matching `route` directive to `/etc/openvpn/client.conf` (the config already carries the working-state pattern from `setup.sh`).

## Verify
```bash
# tunnel endpoints
ping -c3 10.99.99.1

# LAN to LAN — the real test
ip netns exec site-a ping -c3 172.16.20.100

# large payload, DF set — proves the MTU fix
ip netns exec site-a ping -c3 -M do -s 1400 172.16.20.100

# then reboot BOTH and repeat
```

## Root cause, written up
> Three faults across both gateways. The OpenVPN tunnel remained established throughout, masking a broken data plane. (1) `net.ipv4.ip_forward` was 0 on the Site-A gateway, preventing routing between the tunnel and the site LAN. (2) The Site-B gateway was missing its route to `172.16.10.0/24`, eliminating the return path. (3) The tunnel MTU was raised to 1500 while the Site-B carrier interface was reduced to 1400, with MSS clamping disabled and path-MTU discovery forcing DF — creating a black-hole in which small packets passed and full-size payloads were silently dropped, producing hung transfers with no error. Management interfaces were not involved.

---

# Lab 3 — The Raw Log Playground

No faults — this is a build exercise. Below is one correct approach, not the only one.

## What's in the data

- **4 error classes**, injected in **12 time-clustered bursts**: NIC link flaps (`eth1`), TCP retransmission/SYN-flood style events, USB peripheral disconnects, OOM-killer + disk I/O errors.
- **~35% error density inside a burst** — they're findable but not obvious.
- **`auth.log` failure bursts are pinned to the NIC-flap windows.** That's the correlation.
- **~16 malformed lines** across 8 types: garbage timestamps, truncation, missing process field, missing pid brackets, control characters, empty lines.
- **`syslog.1.gz`** holds ~4,500 genuinely older lines (base date precedes the live file).

## The traps

1. **Space-padded day.** `Jul  4 09:00:00` has *two* spaces. `line.split(' ')` yields an empty field and shifts everything. Use `split(None, N)` (splits on runs of whitespace) or a regex.
2. **No year in syslog timestamps.** You must supply one, and handle a year rollover if the range crosses December.
3. **Sorting timestamps as text is wrong.** `"Jul"` < `"Jun"` lexicographically. Convert to a comparable value.
4. **Encoding.** Control characters mean `open(..., errors="replace")` or reading bytes; a plain read can raise.
5. **Rotation ordering.** `.gz` is *older*. Prepend it.

## Reference approach

```python
#!/usr/bin/env python3
"""Parse syslog + auth.log, classify errors, find bursts, correlate."""
import gzip, io, re, sys
from collections import Counter, defaultdict

MONTHS = {m: i for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}

# Space-padded day is why this is a regex and not a split().
LINE = re.compile(
    r'^(?P<mon>[A-Z][a-z]{2})\s+(?P<day>\d{1,2})\s+'
    r'(?P<h>\d{2}):(?P<m>\d{2}):(?P<s>\d{2})\s+'
    r'(?P<host>\S+)\s+(?P<proc>[^:\[]+)(?:\[(?P<pid>\d+)\])?:\s*(?P<msg>.*)$')

CLASSES = {
    "nic_flap":  re.compile(r'NIC Link is (Down|Up)', re.I),
    "tcp_error": re.compile(r'\bTCP\b.*(retransmi|timeout|SYN flooding)|nf_conntrack.*table full', re.I),
    "usb_drop":  re.compile(r'usb .*disconnect', re.I),
    "oom_disk":  re.compile(r'Out of memory|blk_update_request.*I/O error|EXT4-fs error', re.I),
}

def read_lines(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            yield path, n, line.rstrip("\n")

def parse(line):
    m = LINE.match(line)
    if not m:
        return None
    d = m.groupdict()
    mon = MONTHS.get(d["mon"])
    if not mon:
        return None
    # Comparable key. Year is unknown in syslog; a fixed base is fine here
    # because we only ever compare within this dataset.
    key = (mon, int(d["day"]), int(d["h"]), int(d["m"]), int(d["s"]))
    return key, d

def classify(msg):
    for name, rx in CLASSES.items():
        if rx.search(msg):
            return name
    return None

def main():
    counts, malformed, buckets = Counter(), [], defaultdict(Counter)
    # .gz is OLDER — read it first so the timeline is in order.
    for path in ("/var/log/syslog.1.gz", "/var/log/syslog"):
        for src, n, line in read_lines(path):
            if not line.strip():
                malformed.append((src, n, "empty")); continue
            got = parse(line)
            if not got:
                malformed.append((src, n, line[:60])); continue
            key, d = got
            cls = classify(d["msg"])
            if cls:
                counts[cls] += 1
                buckets[(key[0], key[1], key[2])][cls] += 1   # bucket by hour

    print("=== error classes ===")
    for cls, c in counts.most_common():
        print(f"  {cls:10} {c:6}")
    print(f"\nmalformed/unparsed: {len(malformed)}")

    print("\n=== hours with error activity (episodes) ===")
    for hr in sorted(buckets):
        tot = sum(buckets[hr].values())
        if tot:
            print(f"  {hr[0]:02d}-{hr[1]:02d} {hr[2]:02d}:00  total={tot:4}  "
                  + " ".join(f"{k}={v}" for k, v in buckets[hr].items()))

    # --- correlation: NIC-flap hours vs auth failure hours ---
    nic_hours = {hr for hr, c in buckets.items() if c.get("nic_flap")}
    auth_hours = Counter()
    for src, n, line in read_lines("/var/log/auth.log"):
        if "Failed password" in line or "authentication failure" in line:
            got = parse(line)
            if got:
                k = got[0]
                auth_hours[(k[0], k[1], k[2])] += 1

    print("\n=== correlation ===")
    for hr in sorted(set(auth_hours) & nic_hours):
        print(f"  {hr[0]:02d}-{hr[1]:02d} {hr[2]:02d}:00  "
              f"nic_flaps={buckets[hr]['nic_flap']:3}  auth_failures={auth_hours[hr]:3}")

if __name__ == "__main__":
    sys.exit(main())
```

## What "done" looks like

- All four classes identified with counts.
- Errors visibly **clustered** into episodes, not spread evenly.
- The NIC-flap hours and the `auth.log` failure hours **line up** — the correlated windows.
- Malformed lines counted and skipped, never fatal.
- `syslog.1.gz` included, ordered before the live file.

## The lesson

The classification is the easy half. The valuable half is **bucketing by time** — because it converts a pile of strings into *events*, and events are what you escalate, correlate, and write up. `grep -c` gives you a number; a histogram gives you an incident.
---

# Lab 4 — The Name Resolution Failure

> Ticket **NSL-51907**. CT 206 `lab-dns-a` (dnsmasq: DNS + DHCP) and CT 207 `lab-dns-b` (client),
> on the isolated `10.40.40.0/24` segment (vmbr3). Zone: `plant.northstar.example`.

## The three faults

| # | Where | Fault | Found with |
|---|---|---|---|
| 1 | CT 206 | dnsmasq bound to `127.0.0.1` + a DROP on port 53 from eth1 → queries **time out** | `ss -ulnp`, `dig` |
| 2 | CT 207 | Stale `/etc/hosts` entry for `hmi.…` → `getent` and `dig` **disagree** | `getent` vs `dig`, `nsswitch.conf` |
| 3 | CT 206 | Wrong A record for `controller-a` + a 3600s `neg-ttl`/`local-ttl` | `dig` ANSWER + TTL |

## The core skill: what the *failure mode* tells you

Before touching anything, learn to read the four outcomes — they point at completely different layers:

| `dig` says | Meaning | Look at |
|---|---|---|
| `connection timed out; no servers could be reached` | **Nothing answered.** Server down, not listening, or filtered. | `ss -ulnp`, firewall, routing |
| `status: REFUSED` | Something answered and **said no**. Server is up; ACL/policy rejected you. | dnsmasq ACLs, `interface=` scoping |
| `status: NXDOMAIN` | Server answered authoritatively: **that name does not exist**. | the zone data |
| `status: SERVFAIL` | Server tried and **failed** (broken upstream/DNSSEC). | upstream resolver, forwarders |

Fault 1 is engineered to produce a **timeout, not REFUSED** — that's why there's a DROP rule as well as the localhost bind. With nothing listening, the kernel would return ICMP port-unreachable and `dig` would say *connection refused*, which teaches the wrong lesson.

## Fault 1 — the resolver stopped serving the segment

**Detect (server, CT 206):**
```bash
ss -ulnp | grep dnsmasq        # 127.0.0.1:53 — NOT 10.40.40.10:53
ss -tlnp | grep dnsmasq
iptables -L INPUT -n -v        # DROP on 53 from eth1, counters climbing
grep -rn 'listen-address\|interface=' /etc/dnsmasq.d/
```
**Detect (client, CT 207):** `dig @10.40.40.10 controller-a.plant.northstar.example` → `;; connection timed out`.

**Fix (CT 206)** — both artifacts must go:
```bash
sed -i '/^listen-address=127.0.0.1/d' /etc/dnsmasq.d/10-lab-plant.conf
# restore interface scoping + the DHCP range (see the baseline in setup.sh)
iptables -D INPUT -i eth1 -p udp --dport 53 -j DROP
iptables -D INPUT -i eth1 -p tcp --dport 53 -j DROP
dnsmasq --test && systemctl restart dnsmasq
ss -ulnp | grep dnsmasq        # now 10.40.40.10:53
```

## Fault 2 — `/etc/hosts` beats DNS

**What's wrong.** `/etc/nsswitch.conf` has `hosts: files dns` — **files wins**. A stale entry maps `hmi.plant.northstar.example → 10.40.40.199` (nothing there). So `ping`, `curl`, and the operator app all use the wrong address, while `dig` — which talks to DNS directly and **ignores `/etc/hosts` entirely** — returns the correct one.

This is the classic *"but dig says it's fine"* trap. `dig` is not a test of what your application will do. `getent hosts` is, because it goes through NSS.

**Detect (CT 207):**
```bash
getent hosts hmi.plant.northstar.example    # 10.40.40.199   <-- what apps use
dig +short hmi.plant.northstar.example      # the real answer <-- disagrees
grep hosts: /etc/nsswitch.conf
grep plant /etc/hosts
```

**Fix (CT 207):**
```bash
sed -i '/plant.northstar.example/d' /etc/hosts
getent hosts hmi.plant.northstar.example    # now agrees with dig
```
> PVE regenerates `/etc/hosts` on **every container start**, so the lab re-plants this at boot — the persistence unit must be disabled too, or a reboot brings it back.

## Fault 3 — wrong record, and a cache that hides your fix

**What's wrong.** `20-plant-records.conf` serves `controller-a → 10.40.40.77` (wrong). Separately, `90-plant-cache.conf` sets `local-ttl=3600` and `neg-ttl=3600`, so both good and negative answers persist for an hour.

**Two lessons.** First: fixing the record is not enough — the cache must be invalidated. Second: **dnsmasq re-reads `/etc/hosts` on SIGHUP but NOT its own config files**, so `systemctl reload` makes your correct fix look like it failed. A restart is required.

**Detect:**
```bash
dig controller-a.plant.northstar.example     # wrong ANSWER + absurd TTL counting down
grep -rn 'ttl' /etc/dnsmasq.d/
```

**Fix (CT 206):**
```bash
sed -i 's/10.40.40.77/10.40.40.10/' /etc/dnsmasq.d/20-plant-records.conf
rm -f /etc/dnsmasq.d/90-plant-cache.conf
dnsmasq --test && systemctl restart dnsmasq   # restart, NOT reload
dig controller-a.plant.northstar.example      # correct answer, sane TTL
```

## Verify
```bash
# from the client (CT 207)
dig @10.40.40.10 controller-a.plant.northstar.example +short   # 10.40.40.10
getent hosts hmi.plant.northstar.example                        # agrees with dig
ping -c2 controller-a.plant.northstar.example
# DHCP still healthy — client should hold a .100-.150 lease
ip -4 addr show eth1
# then reboot BOTH and repeat
```

## Root cause, written up
> Three faults across the plant name-resolution service. The resolver on CT 206 was bound to the loopback address with ingress DNS additionally filtered, so clients received no response at all rather than a rejection — presenting as a network timeout rather than a name-service error. CT 207 carried a stale static host entry that, because NSS resolves `files` before `dns`, overrode the correct DNS answer for every application while leaving direct DNS queries correct. CT 206 also served an incorrect A record for the controller with a one-hour positive and negative TTL, so corrected records did not take effect until the cache was flushed by a service restart. Management interfaces were not involved at any point.

## Why this lab matters
Name resolution failures are the single most misdiagnosed class of field problem, because they present as connectivity failures. The habit worth building: when a name fails, **immediately test the IP**. If the IP works and the name doesn't, stop looking at the network — you have a resolution problem, and the layer is NSS, the resolver, or the cache.

---

# Appendix A — Lab 1 **v1** (retired fault set)

> Re-arm with `bash /root/fae/lab1-broken-router/break-v1.sh <a|b>` inside the container,
> or keep it retired. Documented here so the original exercise is not lost.

## The v1 faults

## The three faults

| # | Where | Fault | Found with |
|---|---|---|---|
| 1 | CT 202 (B) | `eth1` is `10.10.10.20/28` instead of `/24` | `ip addr` |
| 2 | CT 202 (B) | Bogus routes for the lab segment via `10.10.10.254` (nonexistent) | `ip route` / `ip route get` |
| 3 | CT 201 (A) | Permanent poisoned ARP entry for `10.10.10.20` → `02:de:ad:be:ef:01` | `ip neigh` |

Faults are re-applied at boot by `/usr/local/sbin/lab-faults.sh` via a systemd oneshot, so a reboot won't quietly fix them.

## Fault 1 — the netmask mismatch

**What's wrong.** A `/28` on `10.10.10.20` spans `10.10.10.16–10.10.10.31`. A's `10.10.10.10` falls **outside** it. A (a `/24`) believes B is on-link, ARPs for it, and the echo request *arrives*. B, however, does not consider A on-link, so it can't answer directly — it looks for a route instead.

This is why the symptom is **asymmetric**, and why each box looks fine in isolation. You only see it by comparing them.

**Detect:**
```bash
ip addr show eth1                       # on BOTH — compare the prefixes
tcpdump -ni eth1 icmp                   # on B, while pinging from A: request in, no reply out
```

**Fix (on CT 202):**
```bash
ip addr del 10.10.10.20/28 dev eth1
ip addr add 10.10.10.20/24 dev eth1
```

## Fault 2 — the bogus next-hop

**What's wrong.** B carries:
```
10.10.10.0/24    via 10.10.10.254 dev eth1 onlink
10.10.10.10/32   via 10.10.10.254 dev eth1 onlink
```
`10.10.10.254` doesn't exist. B ARPs for a gateway that never answers, so replies die on B's own outbound path.

The `/32` is there for determinism: with only the `/24`, the injected route and the kernel's connected route have equal prefix length, so which one wins comes down to FIB insertion order. The `/32` is more specific and always wins — the lab behaves the same way every time. Longest-prefix-match decides, which is exactly the rule worth internalising.

**Detect:**
```bash
ip route
ip route get 10.10.10.10                # shows the DECISION, incl. the bogus via
```

**Fix (on CT 202):**
```bash
ip route del 10.10.10.0/24  via 10.10.10.254 dev eth1
ip route get 10.10.10.10                # should now say: dev eth1 src 10.10.10.20
```
Delete by **full specification** (`via ... dev ...`), not just prefix — `ip route del 10.10.10.0/24` alone is ambiguous with the connected route and may remove the wrong one.

## Fault 3 — the poisoned ARP entry

**What's wrong.** A has a static neighbour entry mapping B's IP to a MAC that doesn't exist:
```
10.10.10.20 dev eth1 lladdr 02:de:ad:be:ef:01 PERMANENT
```
Every L3 check now passes, yet frames are addressed to a MAC nobody owns and vanish into the switch fabric. `PERMANENT` means the kernel will never re-learn it — normal entries age out and self-heal; this one can't.

**Detect:**
```bash
ip neigh show dev eth1                  # on A — note PERMANENT and compare the MAC
ip link show eth1                       # on B — B's real MAC
```

**Fix (on CT 201):**
```bash
ip neigh del 10.10.10.20 dev eth1
ping -c1 10.10.10.20                    # re-learn
ip neigh show dev eth1                  # should now be REACHABLE with B's real MAC
```

## Make it survive a reboot

Live `ip` commands are lost on reboot, and the persistence unit re-arms the faults. Disable it and correct the declarative config:

```bash
systemctl disable --now lab-faults.service     # on BOTH containers
rm -f /usr/local/sbin/lab-faults.sh
```
Then confirm `eth1` comes up `/24` on B after `reboot`.

## Verify
```bash
ping -c3 10.10.10.20    # from A
ping -c3 10.10.10.10    # from B
# then reboot both and repeat
```
On the host: `bash /root/fae/deploy.sh status` → FAULTS should read `FIXED`.

## Root cause, written up
> Three independent faults on the `10.10.10.0/24` process segment. CT 202's `eth1` carried a `/28` prefix, placing CT 201 outside its connected subnet and preventing on-link replies. CT 202 additionally held static routes for the segment via a nonexistent next-hop `10.10.10.254`, black-holing traffic that did route. CT 201 held a `PERMANENT` ARP entry mapping `10.10.10.20` to an invalid MAC, so frames were addressed to a nonexistent station even once L3 was correct. Management interfaces were not involved at any point.

---

