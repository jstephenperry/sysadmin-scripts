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
# Usage: sudo ./clone-luks-drive.sh [SOURCE] [TARGET]
#        (or just run it with no args and answer the prompts)
#
# SOURCE and TARGET may be given as a bare kernel name (sdc, nvme0n1), a
# full path (/dev/sdc), or a /dev/disk/by-id symlink.
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

# Accept what the disk list above actually prints. lsblk shows bare kernel
# names (sda, nvme0n1), so typing "sdc" at the prompt is the obvious thing
# to do; requiring a full "/dev/sdc" made that a hard failure. Bare names,
# full paths and /dev/disk/by-id style symlinks are all accepted here and
# normalized to one canonical node path.
normalize_device() {
    local dev="$1" resolved
    dev="${dev#"${dev%%[![:space:]]*}"}"    # strip leading whitespace
    dev="${dev%"${dev##*[![:space:]]}"}"    # strip trailing whitespace
    if [[ -z "$dev" ]]; then
        return 1
    fi
    dev="${dev%/}"                          # strip a trailing slash
    [[ "$dev" == /* ]] || dev="/dev/$dev"
    # Resolve symlinks so SOURCE/TARGET comparisons and the confirmation
    # prompt below all operate on the same canonical path.
    resolved=$(readlink -f "$dev" 2>/dev/null) || resolved=""
    if [[ -n "$resolved" ]]; then
        dev="$resolved"
    fi
    printf '%s' "$dev"
}

# Result of the last select_device call.
DEVICE=""

select_device() {
    local role="$1" prompt="$2" value="${3:-}" candidate attempt
    for attempt in 1 2 3; do
        if [[ -z "$value" ]]; then
            if ! read -rp "$prompt" value; then
                echo >&2
                echo "No $role device provided. Aborting." >&2
                exit 1
            fi
        fi
        candidate=$(normalize_device "$value" || true)
        if [[ -n "$candidate" && -b "$candidate" ]]; then
            DEVICE="$candidate"
            return 0
        fi
        echo "Not a usable block device: ${candidate:-<empty>}" >&2
        echo "Pick one of the NAME values listed above, e.g. $(lsblk -dno NAME -e 7,11 2>/dev/null | head -n1)." >&2
        # A non-interactive run (piped answers, CI) must not spin here.
        [[ -t 0 ]] || exit 1
        value=""
    done
    echo "Too many invalid entries for $role. Aborting." >&2
    exit 1
}

select_device SOURCE \
    "Enter SOURCE device (e.g. /dev/sda or sda) - the OLD, smaller, LUKS drive: " \
    "${1:-}"
SOURCE="$DEVICE"

select_device TARGET \
    "Enter TARGET device (e.g. /dev/sdb or sdb) - the NEW, larger, blank drive: " \
    "${2:-}"
TARGET="$DEVICE"

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

# ---------------------------------------------------------------------------
# 2b. Report the link speed each device is attached on
# ---------------------------------------------------------------------------
# A USB enclosure that negotiated a 480M (USB 2.0) link copies at roughly
# 40 MB/s instead of 400+, turning a six-minute clone into an hour. Nothing
# in lsblk, dmesg or the copy itself flags it, and the usual cause is a
# USB 2.0 or charge-only cable, which is physically indistinguishable from
# a SuperSpeed one. Surface it here rather than leaving it to be worked out
# halfway through the copy.

# Sets LINK_SPEED (Mbps, empty when the device is not on USB), LINK_DRIVER
# (uas or usb-storage) and LINK_TRAN (the lsblk transport).
LINK_SPEED=""
LINK_DRIVER=""
LINK_TRAN=""

probe_link() {
    local dev="$1" sysdir intf drv
    LINK_SPEED=""
    LINK_DRIVER=""
    LINK_TRAN=$(lsblk -dno TRAN "$dev" 2>/dev/null | xargs || true)
    [[ -z "$LINK_TRAN" ]] && LINK_TRAN="unknown"

    sysdir=$(readlink -f "/sys/block/$(basename "$dev")" 2>/dev/null) || return 0
    # Walk up to the owning USB device node. Only a USB device directory has
    # both "speed" and "devnum", so this cannot match a SCSI host or the
    # block device itself.
    while [[ -n "$sysdir" && "$sysdir" != "/" ]]; do
        if [[ -f "$sysdir/speed" && -f "$sysdir/devnum" ]]; then
            LINK_SPEED=$(cat "$sysdir/speed" 2>/dev/null || true)
            # uas vs usb-storage is a property of the interface, not the
            # device. Read the link text rather than resolving it: the target
            # lives outside this subtree and "readlink -f" yields nothing if
            # any parent of it is missing.
            for intf in "$sysdir"/*:*; do
                if [[ -L "$intf/driver" ]]; then
                    drv=$(readlink "$intf/driver" 2>/dev/null || true)
                    LINK_DRIVER="${drv##*/}"
                    break
                fi
            done
            return 0
        fi
        sysdir=$(dirname "$sysdir")
    done
    return 0
}

SLOW_LINKS=""
for role_dev in "SOURCE:$SOURCE" "TARGET:$TARGET"; do
    role="${role_dev%%:*}"
    probe_link "${role_dev#*:}"
    line="$role link: $LINK_TRAN"
    [[ -n "$LINK_SPEED" ]] && line="$line, ${LINK_SPEED}M"
    [[ -n "$LINK_DRIVER" ]] && line="$line, driver=$LINK_DRIVER"
    echo "$line"
    # "speed" can read 1.5 or 12 for low/full-speed devices, so compare on
    # the integer part only and never feed a non-integer to (( )).
    speed_int="${LINK_SPEED%%.*}"
    if [[ "$speed_int" =~ ^[0-9]+$ ]] && (( speed_int <= 480 )); then
        SLOW_LINKS="$SLOW_LINKS $role"
    fi
done

if [[ -n "$SLOW_LINKS" ]]; then
    # 40 MB/s is what USB 2.0 bulk storage realistically sustains; the
    # protocol ceiling is 53.2 MB/s and nothing reaches it.
    SLOW_MINUTES=$(( SRC_SIZE / 40000000 / 60 ))
    echo
    echo "WARNING:$SLOW_LINKS on a USB 2.0 (480M) link."
    echo "  USB 2.0 tops out near 40 MB/s, so copying $(numfmt --to=iec "$SRC_SIZE") will take"
    echo "  roughly $SLOW_MINUTES minutes. On a 5000M/10000M link the same copy takes a"
    echo "  few minutes."
    echo "  Most common cause: a USB 2.0 or charge-only cable. Those are physically"
    echo "  identical to SuperSpeed cables and negotiate 480M with no error anywhere."
    echo "  Check with 'lsusb -t' and look for 5000M or 10000M on the enclosure."
    echo "  Swapping the cable now is usually faster than waiting out the copy."
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
echo "Type the TARGET device ($TARGET) exactly to confirm it will be ERASED:"
read -rp "> " CONFIRM
# Normalized the same way as the selection above, so "nvme0n1" and
# "/dev/nvme0n1" both match; anything else still aborts.
CONFIRM=$(normalize_device "$CONFIRM" || true)
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
    # iflag=fullblock is required when dd reads from a pipe: without it dd
    # accepts the pipe's short reads (64 KiB) as whole blocks and issues
    # thousands of small writes instead of 4 MiB ones, roughly halving
    # throughput on a fast link.
    pv -tpreb "$SOURCE" | dd of="$TARGET" bs=4M iflag=fullblock conv=fsync
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
