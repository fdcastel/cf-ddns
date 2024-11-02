#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

print_usage() {
    echo "Usage: $0 --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [--ttl TTL]" >&2
    echo "Options:" >&2
    echo "  --apiToken TOKEN    Cloudflare API token" >&2
    echo "  --zoneId ZONE_ID   Cloudflare Zone ID" >&2
    echo "  --target HOSTNAME   Target hostname" >&2
    echo "  --source INTERFACE  Network interface (can be specified multiple times)" >&2
    echo "  --ttl TTL          TTL value for DNS records (default: 60)" >&2
    echo "  -h, --help         Show this help message" >&2
}

# Parse arguments
SCRIPT_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --apiToken|--zoneId|--target|--source|--ttl)
            SCRIPT_ARGS+=("$1" "$2")
            if [[ $1 == "--target" ]]; then
                TARGET_NAME="$2"
            fi
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

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/cf-ddns-sync.sh"

if [[ ! -x "$SYNC_SCRIPT" ]]; then
    echo "Error: $SYNC_SCRIPT not found or not executable" >&2
    exit 1
fi

SERVICE_NAME="cf-ddns-$TARGET_NAME"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"

# Create service unit
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Synchronizes DNS records for $TARGET_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SYNC_SCRIPT ${SCRIPT_ARGS[*]} --verbose

[Install]
WantedBy=multi-user.target
EOF

# Create timer unit
cat > "$TIMER_FILE" << EOF
[Unit]
Description=Keeps DNS records for $TARGET_NAME synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# Set proper permissions
chmod 644 "$SERVICE_FILE" "$TIMER_FILE"

# Enable and start the timer
systemctl daemon-reload
systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
systemctl enable --now "$SERVICE_NAME.timer"

echo "Installation complete. Timer $SERVICE_NAME has been enabled and started."
