#!/bin/sh
# Kindle E-Ink Touch Listener (POSIX Shell Fallback)
# Optimized for Kindle Paperwhite 3 (7th Gen) & ForUsers.com

LOG_FILE="/mnt/us/dashboard/touch.log"
exec >> "$LOG_FILE" 2>&1

echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] touch_listener.sh started"

DIR="/mnt/us/dashboard"
CONFIG="${DIR}/config.cfg"

if [ -f "$CONFIG" ]; then
    . "$CONFIG"
fi

SERVER_URL="${SERVER_URL:-https://www.forusers.com}"
ROTATION="${ROTATION:-90}"
EVENT_DEV="${EVENT_DEVICE:-/dev/input/event0}"
HW_WIDTH=1072
HW_HEIGHT=1448

if [ ! -e "$EVENT_DEV" ]; then
    echo "ERROR: Event device $EVENT_DEV does not exist."
    exit 1
fi

echo "Listening on $EVENT_DEV (Rotation: $ROTATION, Server: $SERVER_URL)..."

LAST_TAP=0
CUR_X=-1
CUR_Y=-1

handle_tap() {
    RAW_X="$1"
    RAW_Y="$2"

    if [ "$RAW_X" -lt 0 ] || [ "$RAW_Y" -lt 0 ]; then
        return
    fi

    # Coordinate transformation based on rotation
    case "$ROTATION" in
        90)
            # Landscape (USB on the RIGHT)
            LAND_X="$RAW_Y"
            LAND_Y=$(( (HW_WIDTH - 1) - RAW_X ))
            ;;
        270)
            # Landscape (USB on the LEFT)
            LAND_X=$(( (HW_HEIGHT - 1) - RAW_Y ))
            LAND_Y="$RAW_X"
            ;;
        180)
            LAND_X=$(( (HW_WIDTH - 1) - RAW_X ))
            LAND_Y=$(( (HW_HEIGHT - 1) - RAW_Y ))
            ;;
        *)
            LAND_X="$RAW_X"
            LAND_Y="$RAW_Y"
            ;;
    esac

    echo "[$(date '+%H:%M:%S')] Tap detected at Landscape ($LAND_X, $LAND_Y)"

    # Hit test: Tasks section is X in [525, 1413], Y in [520, 980]
    if [ "$LAND_X" -ge 525 ] && [ "$LAND_X" -le 1413 ] && [ "$LAND_Y" -ge 520 ] && [ "$LAND_Y" -le 980 ]; then
        TASK_IDX=$(( (LAND_Y - 524) / 74 ))
        if [ "$TASK_IDX" -ge 0 ] && [ "$TASK_IDX" -lt 6 ]; then
            echo "[$(date '+%H:%M:%S')] Hit Task Checkbox [Row $TASK_IDX]! Dismissing on server..."
            curl -k -s -S -m 5 -X POST "${SERVER_URL}/api/kindle/tasks/dismiss?index=${TASK_IDX}" >/dev/null 2>&1 &
            # Immediate refresh
            /mnt/us/dashboard/dashboard.sh refresh &
            return
        fi
    fi

    # Tap on weather, clock, or other area -> refresh dashboard
    echo "[$(date '+%H:%M:%S')] Tap on dashboard -> Refreshing..."
    /mnt/us/dashboard/dashboard.sh refresh &
}

# Hexdump loop: outputs "type code value"
hexdump -v -e '1/4 "%*u " 1/4 "%*u " 1/2 "%u " 1/2 "%u " 1/4 "%d\n"' "$EVENT_DEV" | while read -r TYPE CODE VALUE; do
    case "$TYPE $CODE" in
        "3 53"|"3 0")
            CUR_X="$VALUE"
            ;;
        "3 54"|"3 1")
            CUR_Y="$VALUE"
            ;;
        "1 330")
            # BTN_TOUCH release
            if [ "$VALUE" -eq 0 ]; then
                NOW=$(date +%s)
                if [ $(( NOW - LAST_TAP )) -ge 2 ]; then
                    LAST_TAP="$NOW"
                    handle_tap "$CUR_X" "$CUR_Y"
                fi
            fi
            ;;
        "3 57")
            # ABS_MT_TRACKING_ID release (-1)
            if [ "$VALUE" -eq -1 ]; then
                NOW=$(date +%s)
                if [ $(( NOW - LAST_TAP )) -ge 2 ]; then
                    LAST_TAP="$NOW"
                    handle_tap "$CUR_X" "$CUR_Y"
                fi
            fi
            ;;
    esac
done
