#!/bin/sh
# Kindle E-Ink Weather & Calendar Dashboard
# Optimized for Kindle Paperwhite 3 (7th Gen) & ForUsers.com

LOG_FILE="/mnt/us/dashboard/dashboard.log"
exec >> "$LOG_FILE" 2>&1

echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] dashboard.sh started with action: '$1'"

export PATH=/mnt/us/usbnet/bin:/mnt/us/libkh/bin:/usr/bin:/bin:$PATH
export LD_LIBRARY_PATH=/mnt/us/usbnet/lib:/mnt/us/libkh/lib:$LD_LIBRARY_PATH

DIR="/mnt/us/dashboard"
CONFIG="${DIR}/config.cfg"

if [ -f "$CONFIG" ]; then
    . "$CONFIG"
fi

SERVER_URL="${SERVER_URL:-https://www.forusers.com}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-900}"
ROTATION="${ROTATION:-90}"
PREVENT_SLEEP="${PREVENT_SLEEP:-1}"
AUTO_BACKLIGHT="${AUTO_BACKLIGHT:-1}"
BACKLIGHT_PLUGGED_INTENSITY="${BACKLIGHT_PLUGGED_INTENSITY:-14}"
ENABLE_TOUCH="${ENABLE_TOUCH:-1}"

PID_FILE="/tmp/kindle_dashboard.pid"
POWER_PID_FILE="/tmp/kindle_power_monitor.pid"
TOUCH_PID_FILE="/tmp/kindle_touch.pid"
TMP_IMG="/tmp/dashboard.png"

# Setup fbink with image support (usbnet/bin/fbink has full PNG/JPEG support)
setup_fbink() {
    # Check if /tmp/fbink has image support
    if [ -x /tmp/fbink ]; then
        if strings /tmp/fbink 2>/dev/null | grep -q "Supported image formats"; then
            echo "/tmp/fbink"
            return 0
        else
            rm -f /tmp/fbink
        fi
    fi

    # /mnt/us/dashboard/fbink and /mnt/us/usbnet/bin/fbink have full PNG support
    for candidate in /mnt/us/dashboard/fbink /mnt/us/usbnet/bin/fbink; do
        if [ -f "$candidate" ]; then
            cp "$candidate" /tmp/fbink 2>/dev/null
            chmod 755 /tmp/fbink 2>/dev/null
            if [ -x /tmp/fbink ]; then
                echo "/tmp/fbink"
                return 0
            fi
        fi
    done
    echo ""
}

FBINK_BIN=$(setup_fbink)
echo "FBInk binary: ${FBINK_BIN}"

# Manage frontlight based on power status
manage_backlight() {
    if [ "$AUTO_BACKLIGHT" -eq 1 ]; then
        CHARGING=$(lipc-get-prop -i com.lab126.powerd isCharging 2>/dev/null)
        echo "Checking power status: isCharging=${CHARGING}"
        if [ "$CHARGING" = "1" ]; then
            INTENSITY="${BACKLIGHT_PLUGGED_INTENSITY:-14}"
            echo "Device is plugged in: setting frontlight intensity to ${INTENSITY}"
            lipc-set-prop -i com.lab126.powerd flIntensity "$INTENSITY" 2>/dev/null
        else
            echo "Device is on battery: turning frontlight off (intensity 0)"
            lipc-set-prop -i com.lab126.powerd flIntensity 0 2>/dev/null
        fi
    fi
}

display_image() {
    IMG_PATH="$1"
    if [ ! -s "$IMG_PATH" ]; then
        echo "ERROR: Image $IMG_PATH is missing or empty"
        return 1
    fi

    FBINK_BIN=$(setup_fbink)
    if [ -z "$FBINK_BIN" ] || [ ! -x "$FBINK_BIN" ]; then
        echo "ERROR: FBInk executable could not be found"
        return 1
    fi

    echo "Rendering $IMG_PATH to e-ink screen using ${FBINK_BIN}..."
    "$FBINK_BIN" -c -f -i "$IMG_PATH"
    RES=$?
    echo "FBInk exit code: $RES"
    return $RES
}

fetch_and_display() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fetching latest dashboard..."

    # Ensure WiFi is active
    lipc-set-prop -i com.lab126.cmd wirelessEnable 1 2>/dev/null

    # Manage backlight intensity based on plugged in state
    manage_backlight

    # Read battery level
    BATT=$(lipc-get-prop -i com.lab126.powerd battLevel 2>/dev/null)
    if [ -z "$BATT" ]; then
        BATT=-1
    fi
    echo "Battery level: ${BATT}%"

    URL="${SERVER_URL}/kindle/dashboard.png?battery=${BATT}&rotate=${ROTATION}"
    echo "Connecting to: ${URL}"

    rm -f "$TMP_IMG"
    if command -v curl >/dev/null 2>&1; then
        curl -k -L -s -S -f -m 25 "$URL" -o "$TMP_IMG"
        CURL_STATUS=$?
        echo "curl exit code: $CURL_STATUS"
    elif [ -x /mnt/us/usbnet/bin/curl ]; then
        /mnt/us/usbnet/bin/curl -k -L -s -S -f -m 25 "$URL" -o "$TMP_IMG"
        CURL_STATUS=$?
        echo "usbnet curl exit code: $CURL_STATUS"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q -O "$TMP_IMG" "$URL"
        echo "wget completed"
    else
        echo "ERROR: Neither curl nor wget found"
        return 1
    fi

    if [ -s "$TMP_IMG" ]; then
        SIZE=$(ls -l "$TMP_IMG" 2>/dev/null | awk '{print $5}')
        echo "Downloaded $SIZE bytes successfully"
        display_image "$TMP_IMG"
    else
        echo "ERROR: Download failed. Trying backup local image..."
        if [ -s "${DIR}/test.png" ]; then
            display_image "${DIR}/test.png"
        fi
    fi
}

start_touch_listener() {
    if [ "$ENABLE_TOUCH" -ne 1 ]; then
        echo "Touch listener is disabled in config (ENABLE_TOUCH=0)"
        return 0
    fi

    if [ -f "$TOUCH_PID_FILE" ]; then
        TPID=$(cat "$TOUCH_PID_FILE" 2>/dev/null)
        if [ -n "$TPID" ] && kill -0 "$TPID" 2>/dev/null; then
            echo "Touch listener is already running (PID $TPID)"
            return 0
        fi
    fi

    # Prefer compiled touch_listener binary, fallback to touch_listener.sh
    if [ -x "${DIR}/touch_listener" ]; then
        echo "Starting compiled touch listener (${DIR}/touch_listener)..."
        "${DIR}/touch_listener" -config "$CONFIG" >/mnt/us/dashboard/touch.log 2>&1 &
        echo $! > "$TOUCH_PID_FILE"
        echo "Touch listener started (PID $(cat "$TOUCH_PID_FILE"))."
    elif [ -x "${DIR}/touch_listener.sh" ]; then
        echo "Starting shell touch listener (${DIR}/touch_listener.sh)..."
        /bin/sh "${DIR}/touch_listener.sh" >/mnt/us/dashboard/touch.log 2>&1 &
        echo $! > "$TOUCH_PID_FILE"
        echo "Touch listener started (PID $(cat "$TOUCH_PID_FILE"))."
    else
        echo "Warning: No executable touch listener found in ${DIR}"
    fi
}

stop_touch_listener() {
    if [ -f "$TOUCH_PID_FILE" ]; then
        TPID=$(cat "$TOUCH_PID_FILE" 2>/dev/null)
        if [ -n "$TPID" ]; then
            kill "$TPID" 2>/dev/null
        fi
        rm -f "$TOUCH_PID_FILE"
        echo "Touch listener stopped."
    fi
}

start_daemon() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Dashboard daemon is already running (PID $OLD_PID)"
            return 0
        fi
    fi

    echo "Starting Kindle Dashboard daemon (Interval: ${REFRESH_INTERVAL}s, Rotation: ${ROTATION})..."

    if [ "$PREVENT_SLEEP" -eq 1 ]; then
        lipc-set-prop -i com.lab126.powerd preventScreenSaver 1 2>/dev/null
    fi
    lipc-set-prop -i com.lab126.cmd wirelessEnable 1 2>/dev/null

    # Initial fetch & backlight check immediately
    fetch_and_display

    # Start interactive touch monitor
    start_touch_listener

    # Spawn real-time power event monitor for instant backlight switching on plug/unplug
    if [ "$AUTO_BACKLIGHT" -eq 1 ]; then
        (
            lipc-wait-event -m com.lab126.powerd "*" 2>/dev/null | while read line; do
                case "$line" in
                    *charging*|*Charging*|*battLevel*|*power*)
                        manage_backlight
                        ;;
                esac
            done
        ) &
        echo $! > "$POWER_PID_FILE"
    fi

    # Spawn background refresh loop
    (
        while true; do
            sleep "$REFRESH_INTERVAL"
            fetch_and_display
        done
    ) &

    echo $! > "$PID_FILE"
    echo "Daemon started (PID $(cat "$PID_FILE"))."
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        echo "Dashboard daemon stopped."
    else
        echo "Dashboard daemon is not running."
    fi

    if [ -f "$POWER_PID_FILE" ]; then
        P_PID=$(cat "$POWER_PID_FILE" 2>/dev/null)
        if [ -n "$P_PID" ]; then
            kill "$P_PID" 2>/dev/null
        fi
        rm -f "$POWER_PID_FILE"
    fi

    stop_touch_listener

    lipc-set-prop -i com.lab126.powerd preventScreenSaver 0 2>/dev/null
}

case "$1" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    once|refresh)
        sleep 1
        fetch_and_display
        ;;
    test)
        sleep 1
        manage_backlight
        echo "Displaying local test image..."
        display_image "${DIR}/test.png"
        ;;
    status)
        IS_RUNNING=0
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                echo "Dashboard daemon is RUNNING (PID $PID)"
                IS_RUNNING=1
            fi
        fi
        if [ "$IS_RUNNING" -eq 0 ]; then
            echo "Dashboard daemon is STOPPED"
        fi

        if [ -f "$TOUCH_PID_FILE" ]; then
            TPID=$(cat "$TOUCH_PID_FILE" 2>/dev/null)
            if [ -n "$TPID" ] && kill -0 "$TPID" 2>/dev/null; then
                echo "Touch listener is RUNNING (PID $TPID)"
            else
                echo "Touch listener is STOPPED"
            fi
        else
            echo "Touch listener is STOPPED"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|once|test|status}"
        exit 1
        ;;
esac
