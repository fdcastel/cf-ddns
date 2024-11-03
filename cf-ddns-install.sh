#!/bin/bash

set -euo pipefail

function show_help() {
    cat << EOF
Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source IFACE]... [--ttl TTL]

Required arguments:
  --apiToken TOKEN    Cloudflare API Token
  --zoneId ZONE_ID   DNS Zone ID
  --target HOSTNAME   Target hostname

Optional arguments:
  --source IFACE     Network interface(s) (can be specified multiple times)
  --ttl TTL          TTL value (default: 60)
  -h, --help         Show this help message
EOF
    exit 1
}

# Parse arguments
declare -a SCRIPT_ARGS=()
TTL=60

while [[ $# -gt 0 ]]; do
    case $1 in
        --apiToken|--zoneId|--target|--source|--ttl)
            if [[ -z ${2:-} ]]; then
                echo "ERROR: Missing value for $1" >&2
                show_help
            fi
            SCRIPT_ARGS+=("$1" "$2")
            if [[ $1 == "--target" ]]; then
                TARGET_NAME="$2"
            elif [[ $1 == "--ttl" ]]; then
                TTL="$2"
            fi
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

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cf-ddns-${TARGET_NAME}"

# Create service unit
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Synchronizes DNS records for ${TARGET_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/cf-ddns-sync.py ${SCRIPT_ARGS[*]} --verbose

[Install]
WantedBy=multi-user.target
EOF

# Create timer unit
cat > "/etc/systemd/system/${SERVICE_NAME}.timer" << EOF
[Unit]
Description=Keeps DNS records for ${TARGET_NAME} synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# Reload systemd and start service
systemctl daemon-reload
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl enable --now "${SERVICE_NAME}.timer"

echo "Installation complete. Service ${SERVICE_NAME} has been installed and started."
