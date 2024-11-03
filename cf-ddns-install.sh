#!/bin/bash
set -e

# Parse command line arguments
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=""

usage() {
    echo "Usage: $0 --apiToken TOKEN --zoneId ZONE --target HOSTNAME [--source INTERFACE]... [--ttl TTL]"
    echo
    echo "Options:"
    echo "  --apiToken TOKEN   Cloudflare API token"
    echo "  --zoneId ZONE     Cloudflare Zone ID"
    echo "  --target HOSTNAME  Target hostname"
    echo "  --source IFACE    Network interface(s)"
    echo "  --ttl TTL         TTL for DNS records (default: 60)"
    echo "  -h, --help        Show this help message"
    exit 1
}

PARAMS=""
while (( "$#" )); do
    case "$1" in
        -h|--help)
            usage
            ;;
        --apiToken|--zoneId|--target|--source|--ttl)
            if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                if [ "$1" = "--source" ]; then
                    PARAMS="$PARAMS $1 $2"
                else
                    PARAMS="$PARAMS $1 $2"
                fi
                shift 2
            else
                echo "Error: Argument for $1 is missing" >&2
                exit 1
            fi
            ;;
        -*|--*=)
            echo "Error: Unsupported flag $1" >&2
            exit 1
            ;;
        *)
            echo "Error: Unknown argument $1" >&2
            exit 1
            ;;
    esac
done

eval set -- "$PARAMS"

# Validate required arguments
API_TOKEN=""
ZONE_ID=""
TARGET=""
TTL="60"

while [ $# -gt 0 ]; do
    case "$1" in
        --apiToken)
            API_TOKEN="$2"
            shift 2
            ;;
        --zoneId)
            ZONE_ID="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --ttl)
            TTL="$2"
            shift 2
            ;;
        *)
            shift 2
            ;;
    esac
done

[ -z "$API_TOKEN" ] && echo "Error: --apiToken is required" >&2 && exit 1
[ -z "$ZONE_ID" ] && echo "Error: --zoneId is required" >&2 && exit 1
[ -z "$TARGET" ] && echo "Error: --target is required" >&2 && exit 1

# Create systemd service unit
cat > "/etc/systemd/system/cf-ddns-${TARGET}.service" << EOF
[Unit]
Description=Synchronizes DNS records for ${TARGET}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/cf-ddns-sync.py ${PARAMS} --verbose
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

# Create systemd timer unit
cat > "/etc/systemd/system/cf-ddns-${TARGET}.timer" << EOF
[Unit]
Description=Keeps DNS records for ${TARGET} synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# Enable and start the timer
systemctl daemon-reload
systemctl stop "cf-ddns-${TARGET}.timer" 2>/dev/null || true
systemctl enable --now "cf-ddns-${TARGET}.timer"

echo "Installation completed successfully"
