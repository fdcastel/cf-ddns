#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

print_usage() {
    echo "Usage: $0 --target HOSTNAME"
    echo "Options:"
    echo "  --target HOSTNAME  Target hostname to uninstall"
    echo "  -h, --help         Show this help message"
}

# Parse command line arguments
TARGET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET="$2"
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

# Validate required arguments
if [[ -z "$TARGET" ]]; then
    echo "Error: Missing required arguments" >&2
    print_usage
    exit 1
fi

SERVICE_NAME="cf-ddns-${TARGET}"

# Stop and disable the timer
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true

# Remove the service and timer files
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"

# Reload systemd
systemctl daemon-reload
