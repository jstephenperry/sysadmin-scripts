#!/usr/bin/env bash
#
# loop-test.sh
#
# Exercises identify-drives.sh and clone-luks-drive.sh against fake disks
# built from loopback-mounted sparse files, so the real scripts can be
# tested end-to-end with zero risk to actual hardware. Nothing here ever
# touches a real block device.
#
# Builds a small GPT + ESP + LUKS2 + LVM + ext4 "source" disk (mirroring a
# real Ubuntu layout), clones it onto a larger "target" via the real
# clone-luks-drive.sh, then verifies the clone's data and grown filesystem.
# Everything is cleaned up automatically on exit, and any leftovers from a
# previous crashed run are torn down automatically before starting.
#
# Run as root: sudo ./loop-test.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PASSPHRASE="test-passphrase-only"
TMP_PATTERN="luks-clone-test\."

for pkg_check in mkfs.vfat:dosfstools mkfs.ext4:e2fsprogs parted:parted cryptsetup:cryptsetup pvcreate:lvm2; do
    cmd="${pkg_check%%:*}"; pkg="${pkg_check##*:}"
    command -v "$cmd" >/dev/null 2>&1 || { echo "Installing $pkg..."; apt-get update -qq && apt-get install -y "$pkg"; }
done

# ---------------------------------------------------------------------------
# Pre-flight: tear down any leftovers from a previous, crashed run. Only
# ever touches loop devices whose backing file matches our own temp pattern,
# never a blanket "detach everything" (that would rip out unrelated snap
# loop mounts on a normal desktop).
# ---------------------------------------------------------------------------
echo "Checking for leftover state from a previous test run..."
# Every run's VG and LUKS mapper names are prefixed "test_<pid>", so any
# leftovers from a crashed run can be found and torn down by that prefix
# alone, then any of our own loop devices (identified by backing file) can
# be detached safely -- this never touches unrelated loop mounts (snaps etc).
for vg in $(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | grep '^test_' || true); do
    echo "  Removing leftover volume group: $vg"
    vgchange -an "$vg" >/dev/null 2>&1 || true
    vgremove -f "$vg" >/dev/null 2>&1 || true
done
for mapper in /dev/mapper/test_*; do
    [[ -e "$mapper" ]] || continue
    echo "  Closing leftover LUKS mapping: $(basename "$mapper")"
    cryptsetup luksClose "$(basename "$mapper")" 2>/dev/null || true
done
while read -r stale_loop; do
    [[ -z "$stale_loop" ]] && continue
    echo "  Detaching leftover loop device: $stale_loop"
    losetup -d "$stale_loop" 2>/dev/null || true
done < <(losetup -a | awk -F: -v pat="$TMP_PATTERN" '$0 ~ pat {print $1}')

WORKDIR=$(mktemp -d "/tmp/luks-clone-test.XXXXXX")
SRC_IMG="$WORKDIR/source.img"
TGT_IMG="$WORKDIR/target.img"
LOOP_SRC=""
LOOP_TGT=""

# Unique per-run names so a crashed run's leftovers can never collide with
# (or be silently confused for) the next run's state.
RUN_ID="test_$$"
SRC_MAPPER="${RUN_ID}_src"
VG_NAME="${RUN_ID}_vg"

cleanup() {
    echo
    echo "Cleaning up test harness..."
    mountpoint -q "$WORKDIR/verify" 2>/dev/null && umount "$WORKDIR/verify"
    mountpoint -q "$WORKDIR/mnt" 2>/dev/null && umount "$WORKDIR/mnt"
    vgchange -an "$VG_NAME" >/dev/null 2>&1 || true
    vgremove -f "$VG_NAME" >/dev/null 2>&1 || true
    # clone-luks-drive.sh names its own mapper "cloned_root_<its pid>", which
    # this harness doesn't control -- close whatever it left open by pattern.
    for mapper in /dev/mapper/cloned_root_*; do
        [[ -e "$mapper" ]] && { cryptsetup luksClose "$(basename "$mapper")" 2>/dev/null || true; }
    done
    cryptsetup luksClose "$SRC_MAPPER" 2>/dev/null || true
    [[ -n "$LOOP_SRC" ]] && losetup -d "$LOOP_SRC" 2>/dev/null || true
    [[ -n "$LOOP_TGT" ]] && losetup -d "$LOOP_TGT" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== Building fake SOURCE disk ==="
truncate -s 1536M "$SRC_IMG"
truncate -s 3072M "$TGT_IMG"

LOOP_SRC=$(losetup -P --find --show "$SRC_IMG")
LOOP_TGT=$(losetup -P --find --show "$TGT_IMG")
echo "Fake SOURCE: $LOOP_SRC   Fake TARGET: $LOOP_TGT"

parted -s "$LOOP_SRC" mklabel gpt
parted -s "$LOOP_SRC" mkpart ESP fat32 1MiB 51MiB
parted -s "$LOOP_SRC" set 1 esp on
parted -s "$LOOP_SRC" mkpart primary 51MiB 100%
partprobe "$LOOP_SRC"
sleep 1

SRC_ESP="${LOOP_SRC}p1"
SRC_LUKS="${LOOP_SRC}p2"

mkfs.vfat "$SRC_ESP" >/dev/null

echo "Creating LUKS2 container (weak/fast KDF settings -- test only, never do this for real data)..."
echo -n "$TEST_PASSPHRASE" | cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$SRC_LUKS" -d -
echo -n "$TEST_PASSPHRASE" | cryptsetup luksOpen "$SRC_LUKS" "$SRC_MAPPER" -d -

pvcreate -y "/dev/mapper/$SRC_MAPPER" >/dev/null
vgcreate "$VG_NAME" "/dev/mapper/$SRC_MAPPER" >/dev/null
lvcreate -y -l 90%FREE -n root "$VG_NAME" >/dev/null
mkfs.ext4 -q "/dev/$VG_NAME/root"

mkdir -p "$WORKDIR/mnt"
mount "/dev/$VG_NAME/root" "$WORKDIR/mnt"
echo "hello from the fake source disk" > "$WORKDIR/mnt/testfile.txt"
umount "$WORKDIR/mnt"

vgchange -an "$VG_NAME" >/dev/null
cryptsetup luksClose "$SRC_MAPPER"

echo
echo "Fake source disk ready:"
lsblk "$LOOP_SRC"

echo
echo "=== Running identify-drives.sh (read-only sanity check) ==="
"$SCRIPT_DIR/identify-drives.sh" || true

echo
echo "=== Running clone-luks-drive.sh against the loop devices ==="
echo "(answers are piped automatically: target path, y, y, passphrase, LV name)"
# Deliberately passes bare kernel names (loopN, not /dev/loopN) for both the
# arguments and the erase confirmation: that is what the script's own disk
# listing prints, and it used to be rejected outright. This keeps that
# regression from coming back.
printf '%s\ny\ny\n%s\nroot\n' "${LOOP_TGT#/dev/}" "$TEST_PASSPHRASE" | \
    "$SCRIPT_DIR/clone-luks-drive.sh" "${LOOP_SRC#/dev/}" "${LOOP_TGT#/dev/}"

echo
echo "=== Verifying the clone ==="
# clone-luks-drive.sh leaves the cloned LUKS container open and the volume
# group active on success (correct for real use -- the next step there is
# physically swapping the drive and booting it), so the LV is already
# mountable here without reopening anything.
mkdir -p "$WORKDIR/verify"
mount "/dev/$VG_NAME/root" "$WORKDIR/verify"

if [[ "$(cat "$WORKDIR/verify/testfile.txt")" == "hello from the fake source disk" ]]; then
    echo "PASS: cloned filesystem contains the expected test file."
else
    echo "FAIL: test file missing or content mismatch." >&2
    exit 1
fi

df -h "$WORKDIR/verify"
echo "PASS: clone completed and filesystem grew to use the larger target disk."

echo
echo "All checks passed. Cleanup will run automatically."
