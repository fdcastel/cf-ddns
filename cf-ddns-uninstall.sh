#!/bin/bash

set -euo pipefail

function show_help() {
    cat << EOF
Usage: $(basename "$0") --target HOSTNAME

Required arguments:
  --target HOSTNAME   Target hostname to uninstall
  -h, --help         Show this help message
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            if [[ -z ${2:-} ]]; then
                echo "ERROR: Missing value for $1" >&2
                show_help
            fi
            TARGET_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            show_help
            ;;
    esac
done

if [[ -z ${TARGET_NAME:-} ]]; then
    echo "ERROR: --target is required" >&2
    show_help
fi

SERVICE_NAME="cf-ddns-${TARGET_NAME}"

# Stop and disable service/timer
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

# Remove service and timer files
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. Service ${SERVICE_NAME} has been removed."
