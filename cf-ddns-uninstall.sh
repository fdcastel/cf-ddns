#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

print_usage() {
    echo "Usage: $0 --target HOSTNAME" >&2
    echo "Options:" >&2
    echo "  --target HOSTNAME   Target hostname to uninstall" >&2
    echo "  -h, --help         Show this help message" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET_NAME="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

if [[ -z "${TARGET_NAME:-}" ]]; then
    echo "Error: --target argument is required" >&2
    print_usage
    exit 1
fi

SERVICE_NAME="cf-ddns-$TARGET_NAME"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"

# Stop and disable the timer
systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.timer" 2>/dev/null || true

# Remove the service and timer files
rm -f "$SERVICE_FILE" "$TIMER_FILE"

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. Timer $SERVICE_NAME has been removed."
