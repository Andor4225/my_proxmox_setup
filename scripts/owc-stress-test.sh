#!/bin/bash
# owc-stress-test.sh — write-verify stress test for the OWC Express 4M2 enclosure.
#
# Destructive: REFORMATS the target device. Run only on a drive whose contents
# are abandoned. Pass the target device basename as $1 (e.g. sdd).
#
# Method:
#   1. Generate 1GB of random data; checksum it IN-FLIGHT (true ground truth,
#      never depends on the device) while tee-ing it to a seed file.
#   2. Build a 30GB file by appending the seed 30x — sustained write stress.
#   3. sync, drop page caches, read the file back in 1GB chunks, and verify
#      every chunk's sha256 equals the seed's ground-truth checksum.
#
# Catches the failure modes of the previous (ASMedia) enclosure: USB bridge
# resets and I/O errors. Progress + result -> /root/owc-stress.log.
# Exits 0 ONLY on a fully verified run; exits 1 on any failure or mismatch.

set -uo pipefail

TARGET="${1:-}"
SIZE_GB=30
MNT=/mnt/owc-test
LOG=/root/owc-stress.log
WATCHDOG_PID=""

exec >"$LOG" 2>&1
echo "=== OWC stress test START $(date -Is) ==="

fail() {
  echo "FATAL: $* $(date -Is)"
  umount "$MNT" 2>/dev/null || true
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "=== OWC stress test DONE (rc=1) $(date -Is) ==="
  exit 1
}

# --- validate target ---
[ -n "$TARGET" ] || fail "no target device given (pass e.g. sdd)"
DEV="/dev/$TARGET"
[ -b "$DEV" ] || fail "$DEV is not a block device"

TRAN=$(lsblk -ndo TRAN "$DEV" 2>/dev/null) || fail "lsblk failed on $DEV"
[ "$TRAN" = "usb" ] || fail "$DEV transport is '$TRAN', not 'usb' — refusing to format"

# refuse if the device or any child carries an LVM / raid / swap signature
if lsblk -no FSTYPE "$DEV" 2>/dev/null | grep -qiE 'LVM2_member|linux_raid_member|swap'; then
  fail "$DEV carries an LVM/raid/swap signature — refusing to format"
fi
# refuse if the device or any partition is mounted
if lsblk -nro MOUNTPOINT "$DEV" 2>/dev/null | grep -qE '.'; then
  fail "$DEV (or a partition) is mounted — refusing to format"
fi

echo "--- target identity (recorded before format) ---"
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,FSTYPE,LABEL "$DEV"
echo "target $DEV validated: transport=usb, no LVM/raid/swap signature, not mounted"

# --- watchdog: self-terminate a hung run after 2h ---
( sleep 7200; echo "FATAL: watchdog — test exceeded 2h, likely hung $(date -Is)"; kill -9 $$ 2>/dev/null ) &
WATCHDOG_PID=$!

# --- fresh filesystem ---
umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
wipefs -a "$DEV" >/dev/null 2>&1 || true
mkfs.ext4 -F -q -L owc-test "$DEV" || fail "mkfs.ext4 failed on $DEV"
mount "$DEV" "$MNT" || fail "mount of $DEV failed"
echo "filesystem ready $(date -Is)"

# --- 1GB random seed; checksum computed in-flight (ground truth) ---
echo "generating + writing 1GB random seed $(date -Is)"
SEEDSUM=$(dd if=/dev/urandom bs=1M count=1024 status=none | tee "$MNT/seed" | sha256sum | awk '{print $1}') \
  || fail "seed generation/write failed"
[ -n "$SEEDSUM" ] || fail "empty seed checksum"
sync || fail "sync after seed failed"
echo "seed sha256=$SEEDSUM (ground truth, computed in-flight)"

# --- sustained write: append the seed SIZE_GB times ---
echo "writing ${SIZE_GB}GB $(date -Is)"
for i in $(seq 1 "$SIZE_GB"); do
  cat "$MNT/seed" >> "$MNT/bigfile" || fail "write failed at GB $i"
  echo "  wrote ${i}/${SIZE_GB} GB"
done
sync || fail "sync after write failed"
echo "write complete $(date -Is)"

# --- drop caches so readback hits the device, not RAM ---
echo 3 >/proc/sys/vm/drop_caches || fail "drop_caches write failed — readback would be cached, test invalid"
echo "caches dropped, verifying readback $(date -Is)"

# --- verify: read back each 1GB chunk, compare to seed ground truth ---
MISMATCH=0
for i in $(seq 1 "$SIZE_GB"); do
  off=$(( (i - 1) * 1024 ))
  csum=$(dd if="$MNT/bigfile" bs=1M skip="$off" count=1024 status=none | sha256sum | awk '{print $1}') \
    || fail "readback failed at GB $i (I/O error?)"
  [ -n "$csum" ] || fail "empty checksum at GB $i"
  if [ "$csum" != "$SEEDSUM" ]; then
    echo "  MISMATCH at GB $i: got $csum"
    MISMATCH=$((MISMATCH + 1))
  else
    echo "  verified ${i}/${SIZE_GB} GB"
  fi
done

umount "$MNT" 2>/dev/null || echo "WARN: umount returned nonzero"
[ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true

if [ "$MISMATCH" -eq 0 ]; then
  echo "RESULT: VERIFY OK — ${SIZE_GB}GB round-tripped intact, all chunks match seed"
  echo "=== OWC stress test DONE (rc=0) $(date -Is) ==="
  exit 0
else
  echo "RESULT: VERIFY FAILED — $MISMATCH of ${SIZE_GB} chunks corrupted"
  echo "=== OWC stress test DONE (rc=1) $(date -Is) ==="
  exit 1
fi
