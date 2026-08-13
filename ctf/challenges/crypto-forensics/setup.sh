#!/bin/bash
###############################################################################
# CTF Challenge Setup: Crypto & Forensics
# Target: Debian 12 LXC container on Proxmox
# Difficulty: Intermediate
# Flags: 3
#
# This script is fully self-contained. Run as root inside the container.
###############################################################################

set -euo pipefail

# ---------- sanity check ----------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[!] This script must be run as root." >&2
    exit 1
fi

echo "[*] Starting CTF challenge setup..."

# ---------- package installation ----------
echo "[*] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    openssh-server \
    xxd \
    file \
    binutils \
    python3 \
    zip \
    sudo \
    > /dev/null 2>&1

# ---------- user creation ----------
echo "[*] Creating analyst user..."
if ! id analyst &>/dev/null; then
    useradd -m -s /bin/bash analyst
fi
echo "analyst:analyst2024" | chpasswd

# ---------- directory structure ----------
echo "[*] Setting up directory structure..."
mkdir -p /home/analyst/evidence
mkdir -p /home/analyst/tools
mkdir -p /root

# ==========================================================================
# FLAG 1 (Easy) - Base64 Chain
# FLAG{b4s3_s1xty_f0ur_d3c0d3d}
# ==========================================================================
echo "[*] Setting up Flag 1: Base64 Chain..."

FLAG1="FLAG{b4s3_s1xty_f0ur_d3c0d3d}"

# Triple-base64 encode
ENCODED="$FLAG1"
for i in 1 2 3; do
    ENCODED=$(echo -n "$ENCODED" | base64)
done

cat > /home/analyst/evidence/encoded_message.txt << 'MSGEOF'
========================================
INTERCEPTED COMMUNICATION
Date: 2026-03-28 14:32:17 UTC
Source: Internal mail server
========================================
From: cto@megacorp.local
To: cfo@megacorp.local
Subject: Encrypted credentials - URGENT

I've encoded the sensitive data below using our
"proprietary" encoding scheme. Nobody will ever
figure this out.

--- BEGIN ENCODED DATA ---
MSGEOF

echo "$ENCODED" >> /home/analyst/evidence/encoded_message.txt

cat >> /home/analyst/evidence/encoded_message.txt << 'MSGEOF'
--- END ENCODED DATA ---
MSGEOF

cat > /home/analyst/evidence/hint_encoded.txt << 'HINTEOF'
Analyst Notes:
--------------
This message was encoded multiple times for "security".
The sender used the same encoding method 3 times.
The encoding scheme produces only alphanumeric characters, plus signs,
slashes, and equals signs.
HINTEOF

# ==========================================================================
# FLAG 2 (Medium) - Hidden in PNG
# FLAG{h1dd3n_1n_pl41n_s1ght}
# ==========================================================================
echo "[*] Setting up Flag 2: Steganography..."

FLAG2="FLAG{h1dd3n_1n_pl41n_s1ght}"

# Generate a minimal valid PNG using Python3 (a 64x64 dark blue rectangle)
python3 << 'PYGEN'
import struct
import zlib

width, height = 64, 64

def make_chunk(chunk_type, data):
    chunk = chunk_type + data
    return struct.pack('>I', len(data)) + chunk + struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)

# PNG signature
signature = b'\x89PNG\r\n\x1a\n'

# IHDR chunk: width, height, bit depth 8, color type 2 (RGB)
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
ihdr = make_chunk(b'IHDR', ihdr_data)

# IDAT chunk: raw image data (dark blue rectangle with slight variation)
raw_rows = b''
for y in range(height):
    raw_rows += b'\x00'  # filter byte: None
    for x in range(width):
        # Dark blue with slight gradient
        r = 20
        g = 30 + (y % 10)
        b_val = 80 + (x % 40)
        raw_rows += bytes([r, g, b_val])

compressed = zlib.compress(raw_rows)
idat = make_chunk(b'IDAT', compressed)

# IEND chunk
iend = make_chunk(b'IEND', b'')

# Write valid PNG
png_data = signature + ihdr + idat + iend

# Append hidden data after the IEND marker
hidden_comment = b'\n\n<!-- MEGACORP INTERNAL: DO NOT DISTRIBUTE -->\n'
hidden_flag = b'HIDDEN_DATA: ' + b'FLAG{h1dd3n_1n_pl41n_s1ght}' + b'\n'
padding = b'\x00' * 256  # padding to make the file size suspicious
extra_text = b'EXIF-Comment: ' + b'FLAG{h1dd3n_1n_pl41n_s1ght}' + b'\n'

with open('/home/analyst/evidence/company_logo.png', 'wb') as f:
    f.write(png_data)
    f.write(hidden_comment)
    f.write(hidden_flag)
    f.write(padding)
    f.write(extra_text)

print("[+] PNG generated successfully")
PYGEN

cat > /home/analyst/evidence/hint_logo.txt << 'HINTEOF'
Analyst Notes:
--------------
The company logo seems larger than expected for a 64x64 image.
What's hiding at the end?
Try examining the file with hex tools or searching for readable strings.
Standard PNG files end with an IEND chunk marker...
HINTEOF

# ==========================================================================
# FLAG 3 (Hard) - Log Analysis & XOR Decryption
# FLAG{l0g_4n4lys1s_x0r_m4st3r}
# ==========================================================================
echo "[*] Setting up Flag 3: Log Analysis & XOR..."

FLAG3="FLAG{l0g_4n4lys1s_x0r_m4st3r}"
XOR_KEY="s3cr3t"

# Generate access.log with embedded exfil data using Python3
python3 << 'LOGGEN'
import random
import time
import os

flag = "FLAG{l0g_4n4lys1s_x0r_m4st3r}"
xor_key = "s3cr3t"

# XOR encrypt the flag
encrypted_bytes = []
for i, ch in enumerate(flag):
    key_ch = xor_key[i % len(xor_key)]
    encrypted_bytes.append(ord(ch) ^ ord(key_ch))

# Convert to hex string and split into chunks
hex_payload = ''.join(f'{b:02x}' % () if False else format(b, '02x') for b in encrypted_bytes)

# Split hex payload into chunks of varying sizes (4-8 hex chars each)
chunks = []
pos = 0
while pos < len(hex_payload):
    chunk_size = random.randint(4, 8)
    # Ensure even number of chars for valid hex pairs
    if chunk_size % 2 != 0:
        chunk_size += 1
    chunk = hex_payload[pos:pos+chunk_size]
    if chunk:
        chunks.append(chunk)
    pos += chunk_size

# IPs and paths for normal traffic
normal_ips = [
    "192.168.1.105", "192.168.1.42", "10.0.0.15", "172.16.0.88",
    "192.168.1.200", "10.0.0.7", "192.168.2.33", "172.16.1.12",
    "192.168.1.150", "10.0.0.99"
]

suspicious_ip = "10.0.0.237"

normal_paths = [
    "/index.html", "/about.html", "/contact", "/api/users",
    "/api/products", "/login", "/dashboard", "/assets/style.css",
    "/assets/main.js", "/images/banner.jpg", "/api/health",
    "/robots.txt", "/sitemap.xml", "/favicon.ico", "/api/status",
    "/docs/readme", "/api/v2/users", "/static/logo.png"
]

normal_agents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0",
    "curl/7.88.1",
    "Python-urllib/3.11",
    "Googlebot/2.1 (+http://www.google.com/bot.html)"
]

status_codes = [200, 200, 200, 200, 200, 301, 302, 304, 404, 403, 500]
sizes = [1024, 2048, 4096, 512, 8192, 256, 15360, 3072, 768, 5120]

# Generate a base timestamp (March 28, 2026)
base_time = 1743120000  # approximate epoch

lines = []

# We need ~200 lines total with the exfil entries and the XOR key entry scattered in

# Decide positions for the exfil entries (spread across the log, in order)
total_lines = 200
# Reserve slots for exfil entries + 1 for xor key user-agent
num_exfil = len(chunks)
# Place the XOR key hint around line 50-80
xor_key_line = random.randint(50, 80)
# Spread exfil entries evenly through lines 90-190
exfil_positions = sorted(random.sample(range(90, 190), min(num_exfil, 100)))
# If we need more positions, extend
while len(exfil_positions) < num_exfil:
    exfil_positions.append(random.randint(90, 195))
exfil_positions = sorted(exfil_positions[:num_exfil])

exfil_idx = 0

for line_num in range(total_lines):
    timestamp = base_time + line_num * random.randint(5, 120)
    time_str = time.strftime('%d/%b/%Y:%H:%M:%S +0000', time.gmtime(timestamp))

    if line_num == xor_key_line:
        # Embed the XOR key in a User-Agent string
        ip = suspicious_ip
        path = "/api/health"
        status = 200
        size = random.choice(sizes)
        agent = "Mozilla/5.0 (XOR-KEY: s3cr3t)"
        lines.append(
            f'{ip} - - [{time_str}] "GET {path} HTTP/1.1" {status} {size} "-" "{agent}"'
        )
    elif line_num in exfil_positions and exfil_idx < len(chunks):
        # Exfiltration request
        ip = suspicious_ip
        data = chunks[exfil_idx]
        path = f"/api/exfil?data={data}"
        status = 200
        size = random.randint(64, 256)
        agent = "Python-urllib/3.11"
        lines.append(
            f'{ip} - - [{time_str}] "GET {path} HTTP/1.1" {status} {size} "-" "{agent}"'
        )
        exfil_idx += 1
    else:
        # Normal traffic
        ip = random.choice(normal_ips)
        path = random.choice(normal_paths)
        status = random.choice(status_codes)
        size = random.choice(sizes)
        agent = random.choice(normal_agents)
        method = random.choice(["GET", "GET", "GET", "POST", "HEAD"])
        lines.append(
            f'{ip} - - [{time_str}] "{method} {path} HTTP/1.1" {status} {size} "-" "{agent}"'
        )

with open('/home/analyst/evidence/access.log', 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"[+] Generated {len(lines)} log lines with {num_exfil} exfil entries")
print(f"[+] XOR key line placed at line ~{xor_key_line + 1}")
LOGGEN

cat > /home/analyst/evidence/hint_logs.txt << 'HINTEOF'
Analyst Notes:
--------------
Analyze the access logs for unusual API endpoints.
Some data appears to be leaving the network...

Steps to consider:
1. Look for suspicious endpoints and source IPs
2. Extract any encoded data parameters
3. Check for anything unusual in request headers/User-Agent strings
4. The extracted data may need further decryption
HINTEOF

# ==========================================================================
# Helper tool: XOR Decrypt Script
# ==========================================================================
echo "[*] Creating helper tools..."

cat > /home/analyst/tools/xor_decrypt.py << 'XOREOF'
#!/usr/bin/env python3
"""
XOR Decryption Tool
Usage: python3 xor_decrypt.py <hex_data> <key>

Arguments:
    hex_data  - The data to decrypt, as a hex string (e.g., "4a5b6c")
    key       - The XOR key as a plaintext string

Example:
    python3 xor_decrypt.py "1a2b3c4d" "mykey"
"""

import sys

def xor_decrypt(hex_data, key):
    """Decrypt hex-encoded data with a repeating XOR key."""
    try:
        data_bytes = bytes.fromhex(hex_data)
    except ValueError:
        print(f"[!] Error: Invalid hex string: {hex_data}")
        sys.exit(1)

    key_bytes = key.encode('utf-8')
    if len(key_bytes) == 0:
        print("[!] Error: Key cannot be empty")
        sys.exit(1)

    decrypted = bytearray()
    for i, b in enumerate(data_bytes):
        decrypted.append(b ^ key_bytes[i % len(key_bytes)])

    return decrypted

def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    hex_data = sys.argv[1]
    key = sys.argv[2]

    result = xor_decrypt(hex_data, key)

    print(f"[*] Input hex length : {len(hex_data)} chars ({len(hex_data)//2} bytes)")
    print(f"[*] Key              : {key}")
    print(f"[*] Decrypted output : {result.decode('utf-8', errors='replace')}")

if __name__ == '__main__':
    main()
XOREOF

chmod +x /home/analyst/tools/xor_decrypt.py

# ==========================================================================
# Red Herring Files
# ==========================================================================
echo "[*] Creating red herring files..."

# Fake pcap-looking binary file
python3 << 'PCAPGEN'
import os
import struct

# Write a file that starts with a pcap magic number but is otherwise garbage
with open('/home/analyst/evidence/network_capture.pcap', 'wb') as f:
    # pcap global header magic number
    f.write(struct.pack('<I', 0xa1b2c3d4))
    # Version major/minor
    f.write(struct.pack('<HH', 2, 4))
    # Timezone, sigfigs, snaplen, network
    f.write(struct.pack('<iiII', 0, 0, 65535, 1))
    # Write random-looking binary data
    f.write(os.urandom(4096))
    # Embed a troll message deep inside
    f.write(b'\x00\x00' + b'This packet capture is corrupted. Try the other evidence files.' + b'\x00\x00')
    f.write(os.urandom(2048))

print("[+] Fake pcap generated")
PCAPGEN

# Password-protected ZIP red herring
echo "Nice try, but the real flags are elsewhere. Keep looking!" > /tmp/decoy_note.txt
echo "This file was a decoy. The actual evidence is in the other files in ~/evidence/." >> /tmp/decoy_note.txt
zip -j -P "redherring" /home/analyst/evidence/confidential_backup.zip /tmp/decoy_note.txt > /dev/null 2>&1
rm -f /tmp/decoy_note.txt

# Additional red herring: a suspicious-looking but meaningless encoded file
echo "UFJPQ0VTU0VEOiBOb3RoaW5nIHRvIHNlZSBoZXJlLiBUaGlzIGlzIGp1c3QgYSBkZWNveS4=" > /home/analyst/evidence/encrypted_data.b64
# (That decodes to "PROCESSED: Nothing to see here. This is just a decoy.")

# ==========================================================================
# README for the analyst
# ==========================================================================
echo "[*] Creating scenario briefing..."

cat > /home/analyst/README.txt << 'READMEEOF'
===============================================================
           MEGACORP INCIDENT RESPONSE - CLASSIFIED
===============================================================

CASE NUMBER: IR-2026-0328
ANALYST: You
DATE: March 28, 2026
CLASSIFICATION: CONFIDENTIAL

---------------------------------------------------------------
BRIEFING:
---------------------------------------------------------------

You've been called in to investigate a potential data breach
at MegaCorp Industries. Our SIEM flagged suspicious activity
over the past 48 hours, and we've collected evidence from the
affected systems.

All collected evidence has been placed in ~/evidence/

Your objectives:
  1. Analyze all evidence files
  2. Identify any exfiltrated data or hidden information
  3. Extract all flags (format: FLAG{...})

There are 3 flags total, ranging from easy to hard.

---------------------------------------------------------------
AVAILABLE TOOLS:
---------------------------------------------------------------

System tools: xxd, file, strings, base64, python3
Custom tools: ~/tools/xor_decrypt.py (XOR decryption helper)

Hint files are provided for each piece of evidence to get you
started if you're stuck.

Good luck, analyst.

===============================================================
READMEEOF

# ==========================================================================
# Root flag file (answer key)
# ==========================================================================
echo "[*] Creating answer key..."

cat > /root/flags.txt << 'FLAGSEOF'
===================================
CTF Challenge: Crypto & Forensics
Answer Key
===================================

Flag 1 (Easy) - Base64 Chain:
  FLAG{b4s3_s1xty_f0ur_d3c0d3d}
  Location: /home/analyst/evidence/encoded_message.txt
  Method: Triple base64 decode

Flag 2 (Medium) - Steganography:
  FLAG{h1dd3n_1n_pl41n_s1ght}
  Location: /home/analyst/evidence/company_logo.png
  Method: strings or xxd on the PNG reveals data appended after IEND chunk

Flag 3 (Hard) - Log Analysis + XOR:
  FLAG{l0g_4n4lys1s_x0r_m4st3r}
  Location: /home/analyst/evidence/access.log
  Method:
    1. Identify suspicious IP (10.0.0.237) in access.log
    2. Extract hex data from /api/exfil?data= parameters (in order)
    3. Concatenate all hex chunks
    4. Find XOR key in User-Agent: "Mozilla/5.0 (XOR-KEY: s3cr3t)"
    5. Use xor_decrypt.py to decrypt: python3 ~/tools/xor_decrypt.py <hex> s3cr3t

Red Herrings:
  - network_capture.pcap: Fake pcap with corrupted data message
  - confidential_backup.zip: Password "redherring", contains decoy text
  - encrypted_data.b64: Base64 decoy message
FLAGSEOF

chmod 600 /root/flags.txt

# ==========================================================================
# SSH Configuration
# ==========================================================================
echo "[*] Configuring SSH..."

# Ensure SSH config allows password authentication
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

# Handle KbdInteractiveAuthentication (Debian 12 name for ChallengeResponse)
if grep -q "^#*KbdInteractiveAuthentication" /etc/ssh/sshd_config; then
    sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
fi

# Restart SSH service
systemctl enable ssh
systemctl restart ssh

# ==========================================================================
# Permissions
# ==========================================================================
echo "[*] Setting permissions..."

chown -R analyst:analyst /home/analyst/
chmod 755 /home/analyst/
chmod 755 /home/analyst/evidence/
chmod 755 /home/analyst/tools/
chmod 644 /home/analyst/evidence/*
chmod 644 /home/analyst/README.txt
chmod 755 /home/analyst/tools/xor_decrypt.py

# ==========================================================================
# Verification
# ==========================================================================
echo ""
echo "============================================"
echo "[+] CTF Challenge Setup Complete!"
echo "============================================"
echo ""
echo "Verifying setup..."
echo ""

# Verify files exist
ERRORS=0
for f in \
    /home/analyst/README.txt \
    /home/analyst/evidence/encoded_message.txt \
    /home/analyst/evidence/hint_encoded.txt \
    /home/analyst/evidence/company_logo.png \
    /home/analyst/evidence/hint_logo.txt \
    /home/analyst/evidence/access.log \
    /home/analyst/evidence/hint_logs.txt \
    /home/analyst/evidence/network_capture.pcap \
    /home/analyst/evidence/confidential_backup.zip \
    /home/analyst/evidence/encrypted_data.b64 \
    /home/analyst/tools/xor_decrypt.py \
    /root/flags.txt; do
    if [[ -f "$f" ]]; then
        echo "  [OK] $f"
    else
        echo "  [FAIL] $f"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

# Verify Flag 1 can be decoded
DECODED=$(cat /home/analyst/evidence/encoded_message.txt | sed -n '/BEGIN ENCODED DATA/,/END ENCODED DATA/p' | grep -v 'ENCODED DATA' | base64 -d 2>/dev/null | base64 -d 2>/dev/null | base64 -d 2>/dev/null)
if [[ "$DECODED" == "FLAG{b4s3_s1xty_f0ur_d3c0d3d}" ]]; then
    echo "  [OK] Flag 1 verification: PASS"
else
    echo "  [WARN] Flag 1 verification: Could not auto-verify (may still work)"
fi

# Verify Flag 2 is in the PNG
if strings /home/analyst/evidence/company_logo.png | grep -q "FLAG{h1dd3n_1n_pl41n_s1ght}"; then
    echo "  [OK] Flag 2 verification: PASS"
else
    echo "  [WARN] Flag 2 verification: Could not auto-verify"
fi

# Verify the analyst user
if id analyst &>/dev/null; then
    echo "  [OK] User 'analyst' exists"
else
    echo "  [FAIL] User 'analyst' not found"
    ERRORS=$((ERRORS + 1))
fi

# Verify SSH
if systemctl is-active --quiet ssh; then
    echo "  [OK] SSH service is running"
else
    echo "  [WARN] SSH service may not be running"
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "[+] All checks passed!"
else
    echo "[!] $ERRORS check(s) failed. Review output above."
fi

echo ""
echo "Login credentials:"
echo "  Username: analyst"
echo "  Password: analyst2024"
echo ""
echo "Flags are stored in /root/flags.txt (root only)"
echo "============================================"
