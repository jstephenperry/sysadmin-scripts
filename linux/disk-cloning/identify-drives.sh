#!/usr/bin/env bash
# Read-only drive identification helper for a live-USB disk clone.
# Does NOT modify anything: no dd, no wipefs, no mkfs, no partitioning.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Note: run with sudo for full model/serial info (continuing without it)." >&2
fi

echo "=============================================="
echo " All disks (top-level block devices only)"
echo "=============================================="
lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL,ROTA 2>/dev/null

echo
echo "=============================================="
echo " Full tree: disks, partitions, LUKS, mounts"
echo "=============================================="
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,UUID

echo
echo "=============================================="
echo " Per-disk detail"
echo "=============================================="
for disk in $(lsblk -dno NAME -e 7,11 2>/dev/null); do
    dev="/dev/$disk"
    size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "?")
    model=$(cat "/sys/block/$disk/device/model" 2>/dev/null | xargs || echo "unknown")
    serial=$(udevadm info --query=property --name="$dev" 2>/dev/null | grep -m1 '^ID_SERIAL_SHORT=' | cut -d= -f2 || echo "unknown")
    tran=$(lsblk -dno TRAN "$dev" 2>/dev/null || echo "?")

    echo "--- $dev ---"
    echo "  Size:      $size"
    echo "  Model:     $model"
    echo "  Serial:    $serial"
    echo "  Transport: $tran"

    # Flag any LUKS-encrypted partitions on this disk -- likely the SOURCE.
    luks_found=false
    for part in $(lsblk -lno NAME "$dev" | tail -n +2); do
        pdev="/dev/$part"
        fstype=$(blkid -s TYPE -o value "$pdev" 2>/dev/null || true)
        if [[ "$fstype" == "crypto_LUKS" ]]; then
            echo "  -> $pdev is LUKS-encrypted (likely part of the SOURCE OS disk)"
            luks_found=true
        fi
    done
    if ! $luks_found; then
        echo "  -> No LUKS signature found on this disk's partitions"
        # A disk with no partition table at all is a strong signal for a blank TARGET.
        if ! lsblk -no PTTYPE "$dev" 2>/dev/null | grep -q .; then
            echo "  -> No partition table detected (looks BLANK -- possible TARGET)"
        fi
    fi
    echo
done

echo "=============================================="
echo " Currently mounted filesystems (avoid these as clone targets!)"
echo "=============================================="
lsblk -lpno NAME,MOUNTPOINT | awk '$2 != "" {print $1" -> "$2}'

echo
echo "=============================================="
echo " Summary reminder"
echo "=============================================="
echo "* SOURCE = the smaller disk, showing a LUKS signature above."
echo "* TARGET = the larger disk, with no partition table / no LUKS."
echo "* Double-check size and model/serial against what you physically installed"
echo "  before running any dd command. dd direction mistakes are irreversible."
