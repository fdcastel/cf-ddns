#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <target_name>"
    exit 1
fi

TARGET="$1"
SERVICE_NAME="cf-ddns-${TARGET}"

# Stop and disable the timer
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true

# Remove the service and timer units
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"

# Reload systemd
systemctl daemon-reload

# Remove cache file if it exists
rm -f "/var/cache/cf-ddns/${TARGET}.cache"

echo "Uninstallation completed successfully"
