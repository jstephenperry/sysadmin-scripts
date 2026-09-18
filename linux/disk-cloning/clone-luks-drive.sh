#!/usr/bin/env bash
#
# clone-luks-drive.sh
#
# Clones an entire LUKS-encrypted Ubuntu install (partition table, EFI
# partition, LUKS container) from SOURCE to a larger TARGET disk, then
# grows the partition / LUKS container / LVM / filesystem to use the
# new space.
#
# Run this from a LIVE USB session, NOT from the installed OS.
# The SOURCE disk is only ever READ. The TARGET disk is COMPLETELY ERASED.
#
# Usage: sudo ./clone-luks-drive.sh [/dev/SOURCE] [/dev/TARGET]
#        (or just run it with no args and answer the prompts)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Must be root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Dependency check / install
# ---------------------------------------------------------------------------
declare -A CMD_TO_PKG=(
    [sgdisk]=gdisk
    [parted]=parted
    [partprobe]=parted
    [cryptsetup]=cryptsetup
    [pvresize]=lvm2
    [resize2fs]=e2fsprogs
    [pv]=pv
)

missing_pkgs=()
for cmd in "${!CMD_TO_PKG[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_pkgs+=("${CMD_TO_PKG[$cmd]}")
    fi
done

if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
    echo "Installing missing packages: ${missing_pkgs[*]}"
    apt-get update
    apt-get install -y "${missing_pkgs[@]}"
else
    echo "All required tools are already present."
fi

for cmd in dd lsblk blkid blockdev udevadm numfmt; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required base tool: $cmd" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 2. Select source and target
# ---------------------------------------------------------------------------
echo
echo "=== Current disks ==="
lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL
echo

SOURCE="${1:-}"
TARGET="${2:-}"

if [[ -z "$SOURCE" ]]; then
    read -rp "Enter SOURCE device (e.g. /dev/sda) - the OLD, smaller, LUKS drive: " SOURCE
fi
if [[ -z "$TARGET" ]]; then
    read -rp "Enter TARGET device (e.g. /dev/sdb) - the NEW, larger, blank drive: " TARGET
fi

for dev in "$SOURCE" "$TARGET"; do
    [[ -b "$dev" ]] || { echo "Not a block device: $dev" >&2; exit 1; }
done

if [[ "$SOURCE" == "$TARGET" ]]; then
    echo "SOURCE and TARGET must be different devices." >&2
    exit 1
fi

SRC_SIZE=$(blockdev --getsize64 "$SOURCE")
TGT_SIZE=$(blockdev --getsize64 "$TARGET")

echo
echo "SOURCE: $SOURCE  ($(numfmt --to=iec "$SRC_SIZE"))  -- READ ONLY"
lsblk "$SOURCE"
echo
echo "TARGET: $TARGET  ($(numfmt --to=iec "$TGT_SIZE"))  -- WILL BE COMPLETELY ERASED"
lsblk "$TARGET"
echo

if (( TGT_SIZE < SRC_SIZE )); then
    echo "TARGET is smaller than SOURCE. Aborting." >&2
    exit 1
fi

# Refuse if target (or any of its partitions) is mounted or in active use.
if lsblk -no MOUNTPOINT "$TARGET" 2>/dev/null | grep -q .; then
    echo "TARGET has a mounted partition. Unmount it first. Aborting." >&2
    exit 1
fi
if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${TARGET}"; then
    echo "TARGET is in use as swap. Aborting." >&2
    exit 1
fi

# Detect whether TARGET already has a partition table or filesystem on it.
TARGET_IS_BLANK=true
if lsblk -no PTTYPE "$TARGET" 2>/dev/null | grep -q .; then
    TARGET_IS_BLANK=false
fi
if [[ $(lsblk -lno NAME "$TARGET" | wc -l) -gt 1 ]]; then
    TARGET_IS_BLANK=false
fi
if blkid -s TYPE -o value "$TARGET" >/dev/null 2>&1; then
    TARGET_IS_BLANK=false
fi

if ! $TARGET_IS_BLANK; then
    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT "$TARGET"
    echo
    echo "WARNING: $TARGET is not blank. Continuing will permanently erase"
    echo "everything currently on it, with no way to undo it."
    read -rp "Type exactly: ERASE ALL DATA   to acknowledge and continue: " WIPE_CONFIRM
    if [[ "$WIPE_CONFIRM" != "ERASE ALL DATA" ]]; then
        echo "Confirmation did not match. Aborting." >&2
        exit 1
    fi
else
    echo "TARGET appears blank (no partition table or filesystem detected)."
fi

echo
echo "Type the TARGET device path exactly to confirm it will be ERASED:"
read -rp "> " CONFIRM
if [[ "$CONFIRM" != "$TARGET" ]]; then
    echo "Confirmation did not match. Aborting." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Raw clone
# ---------------------------------------------------------------------------
echo
echo "Starting raw clone: $SOURCE -> $TARGET"
echo "This copies the full $(numfmt --to=iec "$SRC_SIZE") of SOURCE and will take a while."
read -rp "Proceed with the clone now? [y/N] " GO
[[ "$GO" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

if command -v pv >/dev/null 2>&1; then
    pv -tpreb "$SOURCE" | dd of="$TARGET" bs=4M conv=fsync
else
    dd if="$SOURCE" of="$TARGET" bs=4M status=progress conv=fsync
fi
sync

echo "Raw clone complete."

# ---------------------------------------------------------------------------
# 4. Fix GPT backup header on the (now larger) target
# ---------------------------------------------------------------------------
echo
echo "Fixing secondary GPT header on $TARGET..."
sgdisk -e "$TARGET"
partprobe "$TARGET" || partx -u "$TARGET"
sleep 2

# ---------------------------------------------------------------------------
# 5. Locate the LUKS partition on target and grow it to fill the disk
# ---------------------------------------------------------------------------
echo
echo "Partition layout on $TARGET:"
parted -s "$TARGET" print

LUKS_PART=""
for part in $(lsblk -lno NAME "$TARGET" | tail -n +2); do
    pdev="/dev/$part"
    fstype=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || true)
    if [[ "$fstype" == "crypto_LUKS" ]]; then
        LUKS_PART="$pdev"
    fi
done

if [[ -z "$LUKS_PART" ]]; then
    echo "Could not find a LUKS partition on $TARGET. Stopping here -- inspect manually." >&2
    exit 1
fi

PART_NUM=$(echo "$LUKS_PART" | grep -o '[0-9]*$')
echo "LUKS partition found: $LUKS_PART (partition number $PART_NUM)"
echo "This must be the LAST partition on the disk for the resize below to work."
read -rp "Grow partition $PART_NUM to fill the rest of $TARGET now? [y/N] " GO
[[ "$GO" =~ ^[Yy]$ ]] || { echo "Stopping before partition resize."; exit 1; }

parted -s "$TARGET" resizepart "$PART_NUM" 100%
partprobe "$TARGET" || partx -u "$TARGET"
sleep 2

# ---------------------------------------------------------------------------
# 6. Open and grow the LUKS container
# ---------------------------------------------------------------------------
echo
read -rsp "Enter the LUKS passphrase for $LUKS_PART: " LUKS_PASSPHRASE
echo

MAPPER_NAME="cloned_root_$$"
echo "Opening $LUKS_PART..."
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksOpen "$LUKS_PART" "$MAPPER_NAME" -d -
cleanup() {
    cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "Resizing LUKS container to fill the partition..."
# cryptsetup resize can re-prompt for the passphrase even on an already-open
# mapping (observed in testing), so feed it explicitly rather than letting it
# compete with the rest of this script's stdin.
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup resize "$MAPPER_NAME" -d -
unset LUKS_PASSPHRASE

# ---------------------------------------------------------------------------
# 7. Grow LVM (if present) and the filesystem
# ---------------------------------------------------------------------------
MAPPER_DEV="/dev/mapper/$MAPPER_NAME"

if pvs "$MAPPER_DEV" >/dev/null 2>&1; then
    echo
    echo "LVM physical volume detected on $MAPPER_DEV."
    vgchange -ay >/dev/null
    pvresize "$MAPPER_DEV"

    VG_NAME=$(pvs --noheadings -o vg_name "$MAPPER_DEV" | xargs)
    echo "Logical volumes in volume group '$VG_NAME':"
    lvs "$VG_NAME"
    read -rp "Enter the LV name to extend with the new space (usually the root LV): " LV_NAME

    lvextend -l +100%FREE "/dev/$VG_NAME/$LV_NAME"
    TARGET_FS_DEV="/dev/$VG_NAME/$LV_NAME"
else
    echo "No LVM detected; filesystem sits directly on the LUKS device."
    TARGET_FS_DEV="$MAPPER_DEV"
fi

FSTYPE=$(blkid -s TYPE -o value "$TARGET_FS_DEV" 2>/dev/null || true)
echo
echo "Growing filesystem ($FSTYPE) on $TARGET_FS_DEV..."
case "$FSTYPE" in
    ext2|ext3|ext4)
        resize2fs "$TARGET_FS_DEV"
        ;;
    btrfs)
        echo "btrfs must be resized while mounted. Run manually:"
        echo "  mount $TARGET_FS_DEV /mnt && btrfs filesystem resize max /mnt && umount /mnt"
        ;;
    xfs)
        echo "xfs must be resized while mounted. Run manually:"
        echo "  mount $TARGET_FS_DEV /mnt && xfs_growfs /mnt && umount /mnt"
        ;;
    *)
        echo "Unrecognized filesystem type '$FSTYPE' -- resize it manually."
        ;;
esac

echo
echo "Done. Summary:"
lsblk "$TARGET"
echo
echo "Next steps:"
echo "  1. Leave the OLD drive untouched for now."
echo "  2. Physically swap in $TARGET (or adjust boot order) and boot from it."
echo "  3. Confirm it prompts for your LUKS passphrase and boots normally."
echo "  4. Only after confirming a full, working boot should you repurpose/wipe the old drive."
