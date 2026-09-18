#!/bin/bash
# Install / Update Kindle Weather & Markets Dashboard
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KINDLE_MOUNT="${1:-/media/$USER/Kindle}"

# Auto-detect or mount if not already mounted
if [ ! -d "$KINDLE_MOUNT" ]; then
    echo "Kindle mount point $KINDLE_MOUNT not found. Looking for Kindle partition..."
    KINDLE_DEV=$(lsblk -o NAME,LABEL,MOUNTPOINT -rn | awk '$2=="Kindle"{print "/dev/"$1}' | head -n1)
    if [ -n "$KINDLE_DEV" ]; then
        echo "Found Kindle device at $KINDLE_DEV. Mounting..."
        udisksctl mount -b "$KINDLE_DEV"
        KINDLE_MOUNT="/media/$USER/Kindle"
    else
        echo "Error: Kindle is not connected or mounted at $KINDLE_MOUNT."
        echo "Please plug in your Kindle via USB and try again."
        exit 1
    fi
fi

echo "Installing Kindle Dashboard files to $KINDLE_MOUNT..."

# 1. Copy dashboard directory
mkdir -p "$KINDLE_MOUNT/dashboard"
cp -v "$DIR/dashboard/dashboard.sh" "$KINDLE_MOUNT/dashboard/dashboard.sh"
if [ -f "$DIR/dashboard/touch_listener" ]; then
    cp -v "$DIR/dashboard/touch_listener" "$KINDLE_MOUNT/dashboard/touch_listener"
fi
if [ -f "$DIR/dashboard/touch_listener.sh" ]; then
    cp -v "$DIR/dashboard/touch_listener.sh" "$KINDLE_MOUNT/dashboard/touch_listener.sh"
fi

if [ ! -f "$KINDLE_MOUNT/dashboard/config.cfg" ]; then
    cp -v "$DIR/dashboard/config.cfg" "$KINDLE_MOUNT/dashboard/config.cfg"
else
    echo "Preserving existing $KINDLE_MOUNT/dashboard/config.cfg (use --force to overwrite)"
fi

# 2. Copy KUAL extension
mkdir -p "$KINDLE_MOUNT/extensions/dashboard/bin"
cp -v "$DIR/extensions/dashboard/config.xml" "$KINDLE_MOUNT/extensions/dashboard/config.xml"
cp -v "$DIR/extensions/dashboard/menu.json" "$KINDLE_MOUNT/extensions/dashboard/menu.json"
cp -v "$DIR/dashboard/dashboard.sh" "$KINDLE_MOUNT/extensions/dashboard/bin/dashboard.sh"

# 3. Ensure executable permissions
chmod +x "$KINDLE_MOUNT/dashboard/dashboard.sh" "$KINDLE_MOUNT/extensions/dashboard/bin/dashboard.sh" || true
if [ -f "$KINDLE_MOUNT/dashboard/touch_listener" ]; then
    chmod +x "$KINDLE_MOUNT/dashboard/touch_listener" || true
fi
if [ -f "$KINDLE_MOUNT/dashboard/touch_listener.sh" ]; then
    chmod +x "$KINDLE_MOUNT/dashboard/touch_listener.sh" || true
fi

echo "Syncing filesystem cache..."
sync

echo "Safely unmounting $KINDLE_MOUNT..."
KINDLE_DEV=$(findmnt -n -o SOURCE "$KINDLE_MOUNT" || true)
if [ -n "$KINDLE_DEV" ]; then
    udisksctl unmount -b "$KINDLE_DEV"
    echo "Kindle unmounted safely! You can now disconnect the USB cable."
else
    echo "Sync complete."
fi

echo "Done! Open KUAL -> Weather Dashboard -> Start Dashboard (Auto)."
