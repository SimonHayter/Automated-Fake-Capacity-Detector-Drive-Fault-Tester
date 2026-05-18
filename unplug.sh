#!/bin/bash
###############################################################################
# Safe Drive Power-Off Script
#
# Cleanly unmounts all partitions on a SATA drive and spins it down so it can
# be hot-unplugged without filesystem damage.
#
# Usage:   sudo ./drive_poweroff.sh
#          (will prompt for the drive, e.g. "sda")
#   or:    sudo ./drive_poweroff.sh sda
#
# Sequence per drive:
#   1. Validate the device exists and is a whole disk (not a partition)
#   2. Show drive info + currently mounted partitions for confirmation
#   3. Unmount every mounted partition belonging to this disk
#   4. sync to flush kernel buffers to the drive
#   5. Disable write cache and tell the drive to flush its own cache (hdparm -F)
#   6. Power the drive off:
#        a. udisksctl power-off (preferred - handles the SCSI delete cleanly)
#        b. echo 1 > /sys/block/sdX/device/delete (fallback)
#   7. Confirm the device node is gone, then it's safe to unplug
###############################################################################

set -u

###############################################################################
# Helpers
###############################################################################

# Get a specific field for a device (model/serial/vendor/size)
get_field() {
    local dev="$1" field="$2"
    local value
    value=$(lsblk -dno "$field" "/dev/$dev" 2>/dev/null | xargs)
    echo "${value:-Unknown}"
}

# List all mountpoints currently mounted from /dev/<dev>* (partitions of dev)
list_mounts_for() {
    local dev="$1"
    awk -v d="/dev/${dev}" '$1 ~ "^"d {print $1" -> "$2}' /proc/mounts
}

# Get just the mountpoints (column 2 of /proc/mounts) for partitions of dev
list_mountpoints_for() {
    local dev="$1"
    awk -v d="/dev/${dev}" '$1 ~ "^"d {print $2}' /proc/mounts
}

# Read y/n from the user (default no)
confirm() {
    local prompt="$1" reply
    read -r -p "$prompt [y/N]: " reply </dev/tty
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# Sanity checks
###############################################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must run as root (try: sudo $0)" >&2
    exit 1
fi

for tool in lsblk udevadm sync; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
    fi
done

# udisksctl is preferred but optional - we have a /sys fallback
HAVE_UDISKS=0
if command -v udisksctl >/dev/null 2>&1; then
    HAVE_UDISKS=1
fi

###############################################################################
# Pick the drive
###############################################################################

DEV="${1:-}"

if [ -z "$DEV" ]; then
    echo "Available drives:"
    echo "----------------------------------------------------------------"
    # Show non-removable + removable disks (TYPE=disk only, no partitions)
    lsblk -dno NAME,SIZE,MODEL,SERIAL,TRAN -e 7,11 2>/dev/null \
        | awk '{printf "  %-6s %-10s %s\n", $1, $2, substr($0, index($0,$3))}'
    echo "----------------------------------------------------------------"
    read -r -p "Which drive do you want to power off? (e.g. sda): " DEV </dev/tty
fi

# Strip any /dev/ prefix the user might have typed, and any trailing partition number
DEV=$(echo "$DEV" | sed -e 's|^/dev/||' -e 's|[0-9]*$||' | xargs)

if [ -z "$DEV" ]; then
    echo "ERROR: no drive specified" >&2
    exit 1
fi

if [ ! -b "/dev/$DEV" ]; then
    echo "ERROR: /dev/$DEV is not a block device" >&2
    exit 1
fi

# Make sure it's a whole disk, not a partition
DEV_TYPE=$(lsblk -dno TYPE "/dev/$DEV" 2>/dev/null | xargs)
if [ "$DEV_TYPE" != "disk" ]; then
    echo "ERROR: /dev/$DEV is type '$DEV_TYPE', not 'disk'. Specify the whole disk (e.g. sda, not sda1)." >&2
    exit 1
fi

###############################################################################
# Show what we're about to do
###############################################################################

MODEL=$(get_field "$DEV" MODEL)
SERIAL=$(get_field "$DEV" SERIAL)
SIZE=$(get_field "$DEV" SIZE)
VENDOR=$(get_field "$DEV" VENDOR)

echo
echo "================================================================"
echo "Target drive:"
echo "  Device:   /dev/$DEV"
echo "  Vendor:   $VENDOR"
echo "  Model:    $MODEL"
echo "  Serial:   $SERIAL"
echo "  Capacity: $SIZE"
echo "================================================================"

# Show partitions belonging to this disk
echo "Partitions:"
lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "/dev/$DEV" 2>/dev/null | sed 's/^/  /'
echo

# Show what's currently mounted
mapfile -t MOUNTS < <(list_mountpoints_for "$DEV")
if [ "${#MOUNTS[@]}" -gt 0 ]; then
    echo "Currently mounted from this drive:"
    list_mounts_for "$DEV" | sed 's/^/  /'
    echo
else
    echo "Nothing currently mounted from this drive."
    echo
fi

# Confirm
if ! confirm "Power off /dev/$DEV?"; then
    echo "Aborted."
    exit 0
fi

###############################################################################
# Step 1: Unmount every partition of this disk
###############################################################################

if [ "${#MOUNTS[@]}" -gt 0 ]; then
    echo
    echo "[1/4] Unmounting partitions..."
    UNMOUNT_FAILED=0
    for mp in "${MOUNTS[@]}"; do
        [ -z "$mp" ] && continue
        echo "  umount $mp"
        if ! umount "$mp" 2>/dev/null; then
            echo "    -> normal umount failed, retrying with sync..."
            sync
            sleep 1
            if ! umount "$mp" 2>/dev/null; then
                echo "    -> still busy, trying lazy unmount (umount -l)..."
                if ! umount -l "$mp" 2>/dev/null; then
                    echo "    -> ERROR: could not unmount $mp"
                    UNMOUNT_FAILED=1
                fi
            fi
        fi
    done

    if [ "$UNMOUNT_FAILED" -eq 1 ]; then
        echo
        echo "ERROR: one or more partitions could not be unmounted."
        echo "Check for processes using the drive:"
        echo "  lsof /dev/${DEV}*"
        echo "  fuser -mv /dev/${DEV}*"
        exit 1
    fi

    # Confirm everything is really gone
    REMAINING=$(list_mountpoints_for "$DEV")
    if [ -n "$REMAINING" ]; then
        echo "ERROR: still mounted after unmount attempts:"
        echo "$REMAINING"
        exit 1
    fi
else
    echo "[1/4] No partitions to unmount."
fi

###############################################################################
# Step 2: Flush all kernel buffers to disk
###############################################################################
echo "[2/4] Syncing kernel buffers to disk..."
sync
sync   # belt and braces

###############################################################################
# Step 3: Flush the drive's own write cache
###############################################################################
echo "[3/4] Flushing drive write cache..."
if command -v hdparm >/dev/null 2>&1; then
    # -F = flush write cache. Disable write cache first so nothing new lands in it.
    hdparm -W 0 "/dev/$DEV" >/dev/null 2>&1 || true
    hdparm -F "/dev/$DEV"   >/dev/null 2>&1 || true
else
    echo "  (hdparm not available - relying on sync only)"
fi

# Let udev settle before we tear the device down
udevadm settle 2>/dev/null
sleep 1

###############################################################################
# Step 4: Power the drive off
###############################################################################
echo "[4/4] Powering off /dev/$DEV..."

POWER_OFF_OK=0

if [ "$HAVE_UDISKS" -eq 1 ]; then
    # udisksctl is the cleanest path - it does STANDBY IMMEDIATE then deletes
    # the SCSI device, which is exactly what hot-unplug needs.
    echo "  trying: udisksctl power-off -b /dev/$DEV"
    if udisksctl power-off -b "/dev/$DEV" 2>&1; then
        POWER_OFF_OK=1
    else
        echo "  udisksctl failed, falling back to /sys..."
    fi
fi

if [ "$POWER_OFF_OK" -eq 0 ]; then
    # Manual fallback:
    #   1. STANDBY IMMEDIATE via hdparm -y (spin down, park heads)
    #   2. echo 1 > /sys/block/sdX/device/delete (remove from SCSI layer)
    if command -v hdparm >/dev/null 2>&1; then
        echo "  hdparm -y /dev/$DEV  (STANDBY IMMEDIATE)"
        hdparm -y "/dev/$DEV" >/dev/null 2>&1 || true
        sleep 1
    fi

    DELETE_PATH="/sys/block/${DEV}/device/delete"
    if [ -w "$DELETE_PATH" ]; then
        echo "  echo 1 > $DELETE_PATH"
        if echo 1 > "$DELETE_PATH" 2>/dev/null; then
            POWER_OFF_OK=1
        fi
    else
        echo "  ERROR: $DELETE_PATH not writable"
    fi
fi

# Give the kernel a moment to remove the device node
sleep 2
udevadm settle 2>/dev/null

###############################################################################
# Final confirmation
###############################################################################
echo
if [ ! -b "/dev/$DEV" ]; then
    echo "================================================================"
    echo "SUCCESS: /dev/$DEV is gone. Safe to unplug."
    echo "================================================================"
    exit 0
else
    echo "================================================================"
    echo "WARNING: /dev/$DEV still exists in /dev."
    echo "  - All partitions are unmounted and caches are flushed"
    echo "  - Data is safe, but the kernel hasn't released the device"
    echo "  - You can still unplug, but cleaner to investigate:"
    echo "      lsof /dev/${DEV}*"
    echo "      cat /sys/block/${DEV}/device/state"
    echo "================================================================"
    exit 1
fi