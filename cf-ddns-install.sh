#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Parse command line arguments (reusing from cf-ddns-sync.sh)
API_TOKEN=""
ZONE_ID=""
TARGET=""
SOURCES=()
TTL=60
VERBOSE=false

print_usage() {
    echo "Usage: $0 --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [--ttl TTL] [-v|--verbose]"
    echo "Options:"
    echo "  --apiToken TOKEN    Cloudflare API token"
    echo "  --zoneId ZONE_ID   Cloudflare Zone ID"
    echo "  --target HOSTNAME  Target hostname"
    echo "  --source INTERFACE Network interface (can be specified multiple times)"
    echo "  --ttl TTL          TTL value for DNS records (default: 60)"
    echo "  -v, --verbose      Enable verbose output"
    echo "  -h, --help         Show this help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --apiToken|--zoneId|--target|--source|--ttl|-v|--verbose|-h|--help)
            if [[ $1 == "--apiToken" ]]; then
                API_TOKEN="$2"
            elif [[ $1 == "--zoneId" ]]; then
                ZONE_ID="$2"
            elif [[ $1 == "--target" ]]; then
                TARGET="$2"
            elif [[ $1 == "--source" ]]; then
                SOURCES+=("$2")
            elif [[ $1 == "--ttl" ]]; then
                TTL="$2"
            elif [[ $1 == "-v" ]] || [[ $1 == "--verbose" ]]; then
                VERBOSE=true
                shift
                continue
            elif [[ $1 == "-h" ]] || [[ $1 == "--help" ]]; then
                print_usage
                exit 0
            fi
            shift 2
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$API_TOKEN" || -z "$ZONE_ID" || -z "$TARGET" ]]; then
    echo "Error: Missing required arguments" >&2
    print_usage
    exit 1
fi

# Prepare variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cf-ddns-${TARGET}"
SYSLOG_IDENTIFIER="${SERVICE_NAME//\./_}"
SYNC_SCRIPT="${SCRIPT_DIR}/cf-ddns-sync.sh"

# Build command line arguments
CMD_ARGS=(
    "--apiToken" "$API_TOKEN"
    "--zoneId" "$ZONE_ID"
    "--target" "$TARGET"
    "--ttl" "$TTL"
)
[[ "$VERBOSE" == "true" ]] && CMD_ARGS+=("--verbose")
for src in "${SOURCES[@]}"; do
    CMD_ARGS+=("--source" "$src")
done

# Create service unit file
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Synchronizes DNS records for ${TARGET}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SYNC_SCRIPT} ${CMD_ARGS[*]}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${SYSLOG_IDENTIFIER}

[Install]
WantedBy=multi-user.target
EOF

# Create timer unit file
cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
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

# Reload systemd, stop any existing timer, and enable the new one
systemctl daemon-reload
systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl enable --now "${SERVICE_NAME}.timer"
