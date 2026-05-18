#!/bin/bash
###############################################################################
# Drive Test & Reformat Workflow
#
# Workflow per drive (run in parallel):
#   1. Wipe partition table
#   2. Create new msdos partition table + single partition
#   3. Format as exFAT
#   4. Mount, run f3write + f3read, log results
#   5. Recreate msdos partition table + single partition
#   6. Format as exFAT with label = last 4 of serial number
#   7. Mount the drive
#   8. Create test_reports_XXXX folder (XXXX = last 4 of serial) on the drive
#   9. Move matching Eraser .txt logs (matched by serial INSIDE the file)
#      into that folder, then delete sd?-Erase-Log-*.pdf files
#  10. Move f3 logs to the drive (matched by serial, not device name)
#
# If any step fails (e.g. no eraser logs found), the message is written into
# a /warnings folder on the drive instead of test_reports separates serious
# issues from normal logs so the operator notices them.
#
# All logs are tagged with serial number so device-name shuffling
# does not break tracking.
###############################################################################

# Load drives from drives.conf (format: DRIVES=(sda, sdb, sdc))
CONF_FILE="$(dirname "$0")/drives.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: drives.conf not found at $CONF_FILE" >&2
    exit 1
fi
DRIVES_LINE=$(grep -E '^DRIVES=' "$CONF_FILE" | head -1)
if [ -z "$DRIVES_LINE" ]; then
    echo "ERROR: No DRIVES= line found in $CONF_FILE" >&2
    exit 1
fi
DRIVES_RAW=$(echo "$DRIVES_LINE" | sed 's/^DRIVES=(\(.*\))/\1/')
IFS=',' read -ra _DRIVES_SPLIT <<< "$DRIVES_RAW"
DRIVES=()
for _d in "${_DRIVES_SPLIT[@]}"; do
    _d=$(echo "$_d" | tr -d '[:space:]')
    [ -n "$_d" ] && DRIVES+=("$_d")
done
unset _DRIVES_SPLIT _d DRIVES_LINE DRIVES_RAW

# Where Parted Magic's Eraser drops its logs
ERASER_LOG_DIR="/home/partedmagic"

# Working directories
WORK_DIR="/tmp/drive_workflow"
FINAL_LOG="${WORK_DIR}/final_results.log"
SERIAL_MAP="${WORK_DIR}/serial_map.txt"   # serial -> initial device name

###############################################################################
# Helper functions
###############################################################################

# Get a specific field for a device (model/serial/vendor/size)
# Falls back to udevadm if lsblk returns empty (some controllers hide info)
get_field() {
    local dev="$1" field="$2"
    local value
    value=$(lsblk -dno "$field" "/dev/$dev" 2>/dev/null | xargs)
    if [ -z "$value" ]; then
        local udev_key
        case "$field" in
            VENDOR) udev_key="ID_VENDOR" ;;
            MODEL)  udev_key="ID_MODEL" ;;
            SERIAL) udev_key="ID_SERIAL_SHORT" ;;
            SIZE)   udev_key="" ;;
        esac
        if [ -n "$udev_key" ]; then
            value=$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null \
                    | grep -E "^${udev_key}=" | cut -d= -f2)
        fi
    fi
    echo "${value:-Unknown}"
}

# Generate the standard header block we embed in every log
get_drive_info() {
    local dev="$1"
    local make model serial size
    make=$(get_field   "$dev" VENDOR)
    model=$(get_field  "$dev" MODEL)
    serial=$(get_field "$dev" SERIAL)
    size=$(get_field   "$dev" SIZE)

    cat <<EOF
========================================
Drive:    /dev/$dev
Make:     $make
Model:    $model
Capacity: $size
Serial:   $serial
Date:     $(date '+%Y-%m-%d %H:%M:%S')
========================================
EOF
}

# Last 4 chars of serial (for label) - exFAT labels are max 11 chars,
# all-uppercase with restricted characters. Strip non-alnum just in case.
short_serial() {
    local serial="$1"
    local clean
    clean=$(echo "$serial" | tr -cd '[:alnum:]')
    echo "${clean: -4}" | tr '[:lower:]' '[:upper:]'
}

# Wait for kernel to settle after a partition/format operation
settle() {
    sync
    partprobe "/dev/$1" 2>/dev/null
    udevadm settle
    sleep 1
}

# Find current device name for a drive given its serial number.
find_dev_by_serial() {
    local target_serial="$1" dev current
    for dev in /sys/block/sd*; do
        [ -e "$dev" ] || continue
        current=$(basename "$dev")
        local s
        s=$(get_field "$current" SERIAL)
        if [ "$s" = "$target_serial" ]; then
            echo "$current"
            return 0
        fi
    done
    return 1
}

# Find Eraser .txt logs that mention this serial number anywhere in their content.
# Returns newline-separated list of matching file paths. Empty if none found.
find_eraser_logs_by_serial() {
    local serial="$1"
    [ -d "$ERASER_LOG_DIR" ] || return 0
    # -l = filenames only, -F = fixed string (no regex surprises in serials)
    # Restrict to the eraser txt naming pattern so we don't grep random files.
    grep -lF "$serial" "$ERASER_LOG_DIR"/sd?-Erase-Log-*.txt 2>/dev/null
}

# Append a warning line to a per-worker pending-warnings file. These get
# written to the drive's /warnings folder once it's mounted at the end.
queue_warning() {
    local serial="$1" message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" \
        >> "${WORK_DIR}/warnings_${serial}.log"
}

###############################################################################
# Per-drive worker - runs in background
###############################################################################
process_drive() {
    local dev="$1"
    local SERIAL MODEL SIZE LABEL
    local WRITE_LOG READ_LOG FORMAT_LOG WORKER_LOG

    # Capture identifying info BEFORE we touch anything
    SERIAL=$(get_field "$dev" SERIAL)
    MODEL=$(get_field  "$dev" MODEL)
    SIZE=$(get_field   "$dev" SIZE)
    LABEL=$(short_serial "$SERIAL")

    # All logs named by serial (device-name-agnostic from this point on)
    WRITE_LOG="${WORK_DIR}/f3_write_${SERIAL}.log"
    READ_LOG="${WORK_DIR}/f3_read_${SERIAL}.log"
    FORMAT_LOG="${WORK_DIR}/format_${SERIAL}.log"
    WORKER_LOG="${WORK_DIR}/worker_${SERIAL}.log"

    # Map serial to initial device name (for human reference only)
    echo "$SERIAL=$dev" >> "$SERIAL_MAP"

    exec >>"$WORKER_LOG" 2>&1
    set -x

    local HEADER
    HEADER=$(get_drive_info "$dev")

    echo "$HEADER" > "$WRITE_LOG"
    echo "--- f3write output ---" >> "$WRITE_LOG"
    echo "$HEADER" > "$READ_LOG"
    echo "--- f3read output ---" >> "$READ_LOG"
    echo "$HEADER" > "$FORMAT_LOG"
    echo "--- Partition/Format log ---" >> "$FORMAT_LOG"

    ###########################################################################
    # STEP 1-3: Wipe partition table, create new msdos table, format exFAT
    ###########################################################################
    echo "[STEP 1-3] Preparing /dev/$dev for f3 test..."
    {
        echo ""
        echo "===== PRE-TEST FORMAT ($(date '+%Y-%m-%d %H:%M:%S')) ====="
        echo "Target device: /dev/$dev"
    } >> "$FORMAT_LOG"

    # Make sure nothing is mounted from this drive
    umount "/dev/${dev}"* 2>/dev/null

    # Zap any existing partition table (covers MBR, GPT, and any others)
    echo "--- wipefs ---" >> "$FORMAT_LOG"
    wipefs -a "/dev/$dev" >> "$FORMAT_LOG" 2>&1
    echo "--- dd zero first 10MB ---" >> "$FORMAT_LOG"
    dd if=/dev/zero of="/dev/$dev" bs=1M count=10 conv=fsync >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    # Create new msdos partition table with a single primary partition
    echo "--- parted mklabel msdos ---" >> "$FORMAT_LOG"
    parted -s "/dev/$dev" mklabel msdos >> "$FORMAT_LOG" 2>&1
    echo "--- parted mkpart primary ---" >> "$FORMAT_LOG"
    parted -s -a optimal "/dev/$dev" mkpart primary 1MiB 100% >> "$FORMAT_LOG" 2>&1
    echo "--- parted print ---" >> "$FORMAT_LOG"
    parted -s "/dev/$dev" print >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    # Set partition type to 0x07 (NTFS/exFAT) so Windows recognises the drive.
    # parted defaults to 0x83 (Linux) which Windows silently ignores.
    echo "--- sfdisk set type 0x07 ---" >> "$FORMAT_LOG"
    sfdisk --part-type "/dev/$dev" 1 7 >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    # Format exFAT
    echo "--- mkfs.exfat (pre-test label TEST${LABEL}) ---" >> "$FORMAT_LOG"
    mkfs.exfat -L "TEST${LABEL}" "/dev/${dev}1" >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    ###########################################################################
    # STEP 4: Mount and run f3write + f3read
    ###########################################################################
    echo "[STEP 4] Running f3 test on /dev/$dev (serial: $SERIAL)..."

    local MOUNT_POINT="/mnt/${dev}_test"
    mkdir -p "$MOUNT_POINT"

    if ! mount "/dev/${dev}1" "$MOUNT_POINT"; then
        echo "MOUNT FAILED for /dev/${dev}1 before f3 test"
        queue_warning "$SERIAL" "Mount failed for /dev/${dev}1 before f3 test - drive could not be tested"
        echo "/dev/$dev [${MODEL} | ${SIZE} | SN:${SERIAL}] : MOUNT_FAILED" > "${WORK_DIR}/result_${SERIAL}.line"
        return 1
    fi

    f3write "$MOUNT_POINT" >> "$WRITE_LOG" 2>&1

    # Drop caches between write and read so we hit the drive, not RAM
    umount "$MOUNT_POINT"
    sync
    echo 3 > /proc/sys/vm/drop_caches
    mount "/dev/${dev}1" "$MOUNT_POINT"

    f3read "$MOUNT_POINT" >> "$READ_LOG" 2>&1

    local RESULT SPEED
    if grep -q "Data LOST: 0.00 Byte" "$READ_LOG"; then
        RESULT="PASS"
    else
        RESULT="FAIL"
        queue_warning "$SERIAL" "f3 test FAILED - data loss detected (see f3_read_${SERIAL}.log)"
    fi
    SPEED=$(grep "Average reading speed" "$READ_LOG" | awk -F: '{print $2}' | xargs)

    umount "$MOUNT_POINT" 2>/dev/null
    settle "$dev"

    # Device name should be stable (we removed sanitize) but re-check anyway
    # in case some other rescan happened.
    local current_dev
    current_dev=$(find_dev_by_serial "$SERIAL")
    if [ -z "$current_dev" ]; then
        echo "ERROR: cannot locate drive with serial $SERIAL after f3 test" >> "$WORKER_LOG"
        queue_warning "$SERIAL" "Drive disappeared after f3 test - cannot continue"
        echo "/dev/$dev [${MODEL} | ${SIZE} | SN:${SERIAL}] : $RESULT (Speed: $SPEED) | LOST" > "${WORK_DIR}/result_${SERIAL}.line"
        return 1
    fi
    if [ "$current_dev" != "$dev" ]; then
        echo "NOTE: device name changed: $dev -> $current_dev" >> "$WORKER_LOG"
        dev="$current_dev"
    fi

    ###########################################################################
    # STEP 5-6: Recreate msdos partition table + exFAT formatted with serial label
    ###########################################################################
    echo "[STEP 5-6] Recreating partition + exFAT on /dev/$dev..."
    {
        echo ""
        echo "===== POST-TEST FORMAT ($(date '+%Y-%m-%d %H:%M:%S')) ====="
        echo "Target device: /dev/$dev (serial $SERIAL)"
    } >> "$FORMAT_LOG"

    echo "--- wipefs ---" >> "$FORMAT_LOG"
    wipefs -a "/dev/$dev" >> "$FORMAT_LOG" 2>&1
    echo "--- dd zero first 10MB ---" >> "$FORMAT_LOG"
    dd if=/dev/zero of="/dev/$dev" bs=1M count=10 conv=fsync >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    echo "--- parted mklabel msdos ---" >> "$FORMAT_LOG"
    parted -s "/dev/$dev" mklabel msdos >> "$FORMAT_LOG" 2>&1
    echo "--- parted mkpart primary ---" >> "$FORMAT_LOG"
    parted -s -a optimal "/dev/$dev" mkpart primary 1MiB 100% >> "$FORMAT_LOG" 2>&1
    echo "--- parted print ---" >> "$FORMAT_LOG"
    parted -s "/dev/$dev" print >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    # Set partition type to 0x07 (NTFS/exFAT) so Windows recognises the drive.
    echo "--- sfdisk set type 0x07 ---" >> "$FORMAT_LOG"
    sfdisk --part-type "/dev/$dev" 1 7 >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    # exFAT labels: max 11 chars, must be valid - use last 4 of serial
    echo "--- mkfs.exfat (final label $LABEL) ---" >> "$FORMAT_LOG"
    mkfs.exfat -L "$LABEL" "/dev/${dev}1" >> "$FORMAT_LOG" 2>&1
    settle "$dev"

    ###########################################################################
    # STEP 7: Mount the freshly formatted drive
    ###########################################################################
    echo "[STEP 7] Mounting freshly formatted /dev/${dev}1..."

    local FINAL_MOUNT="/mnt/${LABEL}"
    mkdir -p "$FINAL_MOUNT"
    if ! mount "/dev/${dev}1" "$FINAL_MOUNT"; then
        echo "ERROR: Final mount failed for /dev/${dev}1" >> "$WORKER_LOG"
        queue_warning "$SERIAL" "Final mount failed for /dev/${dev}1 - reports could not be copied to drive"
        echo "/dev/$dev [${MODEL} | ${SIZE} | SN:${SERIAL}] : $RESULT (Speed: $SPEED) | FINAL_MOUNT_FAILED" > "${WORK_DIR}/result_${SERIAL}.line"
        return 1
    fi

    ###########################################################################
    # STEP 8-10: Build test_reports_XXXX folder on drive, copy logs in,
    # find & move Eraser logs by serial, then delete matching PDFs.
    ###########################################################################
    echo "[STEP 8-10] Copying reports + eraser logs onto /dev/${dev}1..."

    local REPORTS_DIR="${FINAL_MOUNT}/test_reports_${LABEL}"
    mkdir -p "$REPORTS_DIR"

    # Copy f3 + format logs (named by serial, so unambiguous)
    cp "$WRITE_LOG"  "$REPORTS_DIR/" 2>/dev/null
    cp "$READ_LOG"   "$REPORTS_DIR/" 2>/dev/null
    cp "$FORMAT_LOG" "$REPORTS_DIR/" 2>/dev/null

    # --- Eraser log handling ---
    # Find .txt eraser logs containing this serial. There should normally be
    # two (Advanced + Basic). If we find zero, queue a warning.
    local ERASER_STATUS="NONE_FOUND"
    local eraser_matches eraser_count=0
    eraser_matches=$(find_eraser_logs_by_serial "$SERIAL")
    if [ -n "$eraser_matches" ]; then
        while IFS= read -r src; do
            [ -f "$src" ] || continue
            # Preserve original filename so the dev-letter/timestamp stays visible
            cp -- "$src" "$REPORTS_DIR/" \
                && rm -f -- "$src" \
                && eraser_count=$(( eraser_count + 1 ))
        done <<< "$eraser_matches"
    fi

    if [ "$eraser_count" -eq 0 ]; then
        ERASER_STATUS="NONE_FOUND"
        queue_warning "$SERIAL" "No Eraser .txt logs found in ${ERASER_LOG_DIR} matching serial ${SERIAL}"
    elif [ "$eraser_count" -lt 2 ]; then
        ERASER_STATUS="PARTIAL_${eraser_count}_of_2"
        queue_warning "$SERIAL" "Only ${eraser_count} Eraser log(s) found for serial ${SERIAL} (expected 2: Advanced + Basic)"
    else
        ERASER_STATUS="OK_${eraser_count}_logs"
    fi

    ###########################################################################
    # If any warnings were queued, drop them on the drive in /warnings
    ###########################################################################
    if [ -f "${WORK_DIR}/warnings_${SERIAL}.log" ]; then
        local WARN_DIR="${FINAL_MOUNT}/warnings"
        mkdir -p "$WARN_DIR"
        {
            echo "$HEADER"
            echo "--- Warnings for this drive ---"
            cat "${WORK_DIR}/warnings_${SERIAL}.log"
        } > "${WARN_DIR}/warnings_${SERIAL}.log"
    fi

    # Drop a one-line summary on the drive too
    cat > "${REPORTS_DIR}/SUMMARY.txt" <<EOF
Drive Test Summary
==================
Model:    $MODEL
Capacity: $SIZE
Serial:   $SERIAL
Label:    $LABEL
Date:     $(date '+%Y-%m-%d %H:%M:%S')

f3 Test:        $RESULT
Read Speed:     $SPEED
Eraser Logs:    $ERASER_STATUS
Format:         exFAT on msdos partition table, label "$LABEL"

Reports in this folder:
  - f3_write_${SERIAL}.log    : f3write capacity/integrity test
  - f3_read_${SERIAL}.log     : f3read verification + speed
  - format_${SERIAL}.log      : Pre- and post-test partition/format ops
  - sd?-Erase-Log-*.txt       : Parted Magic Eraser reports (if found)

If a /warnings folder exists at the root of this drive, review it -
something didn't go as planned.
EOF

    sync
    umount "$FINAL_MOUNT" 2>/dev/null
    # Remount cleanly for the user
    mount "/dev/${dev}1" "$FINAL_MOUNT"

    # Write one-line result to a per-worker file (avoids interleaving with other workers)
    echo "/dev/$dev [${MODEL} | ${SIZE} | SN:${SERIAL}] : $RESULT (Speed: $SPEED) | Eraser: $ERASER_STATUS | Mounted: $FINAL_MOUNT" > "${WORK_DIR}/result_${SERIAL}.line"
    echo "[DONE] /dev/$dev complete."
}

###############################################################################
# Cleanup: kill any orphan workers/tools from previous runs and unmount stragglers
###############################################################################
LOCK_FILE="/var/lock/drive_workflow.lock"

cleanup_previous() {
    echo "================================================================"
    echo "Pre-flight cleanup: killing orphans from previous runs"
    echo "================================================================"

    # 1. Kill orphan instances of THIS script (excluding our own PID and parent).
    local script_name
    script_name=$(basename "$0")
    local our_pid=$$
    local our_ppid=$PPID
    local orphan_pids
    orphan_pids=$(pgrep -af "$script_name" 2>/dev/null \
                  | awk -v sn="$script_name" '$2 ~ /(^|\/)bash$/ && $3 ~ sn"$" {print $1}' \
                  | grep -vE "^(${our_pid}|${our_ppid})$" || true)
    if [ -n "$orphan_pids" ]; then
        echo "Found orphan $script_name processes: $orphan_pids"
        # shellcheck disable=SC2086
        kill -TERM $orphan_pids 2>/dev/null
        sleep 2
        # shellcheck disable=SC2086
        kill -KILL $orphan_pids 2>/dev/null
    else
        echo "No orphan $script_name processes."
    fi

    # 2. Kill any in-flight destructive tools targeting our drives.
    local tool patterns dev pid match_pids=""
    patterns=()
    for dev in "${DRIVES[@]}"; do
        patterns+=("/dev/${dev}" "/mnt/${dev}_test")
    done

    for tool in f3write f3read dd parted mkfs.exfat wipefs; do
        local tool_pids
        tool_pids=$(pgrep -x "$tool" 2>/dev/null || true)
        [ -z "$tool_pids" ] && continue

        for pid in $tool_pids; do
            local cmdline
            cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
            local hit=0
            for p in "${patterns[@]}"; do
                if [[ "$cmdline" == *"$p"* ]]; then hit=1; break; fi
            done
            if [ "$hit" -eq 1 ]; then
                echo "Killing $tool PID $pid (cmd: $cmdline)"
                kill -TERM "$pid" 2>/dev/null
                match_pids="$match_pids $pid"
            fi
        done
    done

    if [ -n "$match_pids" ]; then
        sleep 2
        # shellcheck disable=SC2086
        kill -KILL $match_pids 2>/dev/null
    fi

    # 3. Unmount any stale mount points used by this workflow
    local mp
    for dev in "${DRIVES[@]}"; do
        mp="/mnt/${dev}_test"
        if mountpoint -q "$mp" 2>/dev/null; then
            echo "Unmounting stale: $mp"
            umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null
        fi
    done
    for dev in "${DRIVES[@]}"; do
        while read -r mp; do
            [ -z "$mp" ] && continue
            echo "Unmounting from /dev/${dev}*: $mp"
            umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null
        done < <(awk -v d="/dev/${dev}" '$1 ~ "^"d {print $2}' /proc/mounts)
    done

    udevadm settle
    sleep 1

    echo "Pre-flight cleanup complete."
    echo "================================================================"
}

# Lock file tracks the active run. If a previous run is still alive, this
# new run TAKES OVER by killing the previous run and its child workers.
acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "================================================================"
            echo "Previous drive_workflow.sh still running (PID $old_pid)"
            echo "Taking over: killing previous run and its children..."
            echo "================================================================"
            local old_pgid
            old_pgid=$(ps -o pgid= -p "$old_pid" 2>/dev/null | tr -d ' ')
            if [ -n "$old_pgid" ]; then
                kill -TERM -- "-${old_pgid}" 2>/dev/null
                sleep 2
                kill -KILL -- "-${old_pgid}" 2>/dev/null
            fi
            kill -TERM "$old_pid" 2>/dev/null
            sleep 1
            kill -KILL "$old_pid" 2>/dev/null
        else
            echo "Removing stale lock file (old PID ${old_pid:-unknown} no longer running)"
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# Wipe the working directory of all logs/results from previous runs
reset_work_dir() {
    if [ -d "$WORK_DIR" ]; then
        echo "Clearing previous logs in $WORK_DIR ..."
        rm -rf "${WORK_DIR:?}"/*
    fi
    mkdir -p "$WORK_DIR"
    : > "$FINAL_LOG"
    : > "$SERIAL_MAP"
}

# On any exit (normal or signal), release the lock
trap 'release_lock' EXIT
trap 'echo "Interrupted - cleaning up..."; release_lock; exit 130' INT TERM

###############################################################################
# Main - launch one worker per drive in parallel
###############################################################################

# Sanity: must be root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# Sanity: required tools
for tool in parted mkfs.exfat wipefs partprobe udevadm f3write f3read lsblk pgrep mountpoint; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
    fi
done

# Sanity: every listed drive exists
for dev in "${DRIVES[@]}"; do
    if [ ! -b "/dev/$dev" ]; then
        echo "ERROR: /dev/$dev is not a block device" >&2
        exit 1
    fi
done

echo "================================================================"
echo "Drives loaded from drives.conf:"
for dev in "${DRIVES[@]}"; do
    echo "  /dev/$dev"
done
echo "================================================================"
read -rp "Continue with these drives? [yes/no]: " _confirm
case "${_confirm,,}" in
    yes|y) ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac
unset _confirm

acquire_lock
cleanup_previous
reset_work_dir

echo "================================================================"
echo "Starting workflow for: ${DRIVES[*]}"
echo "Working directory:     $WORK_DIR"
echo "Final summary log:     $FINAL_LOG"
echo "Eraser log source:     $ERASER_LOG_DIR"
echo "================================================================"

PIDS=()
for dev in "${DRIVES[@]}"; do
    process_drive "$dev" &
    PIDS+=($!)
done

echo
echo "Workers launched. Watch progress with:"
echo "  tail -f $FINAL_LOG"
echo "  tail -f ${WORK_DIR}/worker_*.log"
echo

# Wait for everyone
for pid in "${PIDS[@]}"; do
    wait "$pid"
done

###############################################################################
# Post-run: delete sd?-Erase-Log-*.pdf files from the eraser log directory.
# Done ONCE at the end (not per-worker) to avoid races. Only PDFs matching
# the eraser naming pattern are touched - any other PDFs are left alone.
###############################################################################
echo
echo "Cleaning up eraser PDF files in ${ERASER_LOG_DIR} ..."
if [ -d "$ERASER_LOG_DIR" ]; then
    # nullglob so the glob expands to nothing (not the literal pattern) if no matches
    shopt -s nullglob
    pdf_files=( "$ERASER_LOG_DIR"/sd?-Erase-Log-*.pdf )
    shopt -u nullglob
    if [ ${#pdf_files[@]} -gt 0 ]; then
        echo "Deleting ${#pdf_files[@]} eraser PDF(s):"
        for f in "${pdf_files[@]}"; do
            echo "  rm $f"
            rm -f -- "$f"
        done
    else
        echo "No eraser PDFs found to delete."
    fi
else
    echo "WARNING: $ERASER_LOG_DIR does not exist - skipping PDF cleanup"
fi

# Assemble final log from per-worker result lines (avoids interleaving)
for f in "${WORK_DIR}"/result_*.line; do
    [ -f "$f" ] && cat "$f" >> "$FINAL_LOG"
done

echo
echo "================================================================"
echo "ALL DRIVES COMPLETE"
echo "================================================================"
cat "$FINAL_LOG"