#!/bin/bash

set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Display help message
show_help() {
    cat << EOF
Usage: cf-ddns.sh COMMAND [OPTIONS]

Commands:
    install     Install cf-ddns service
    uninstall   Remove cf-ddns service

Options:
    -h, --help          Show this help message
    --target            DNS record to update (required)
    --apiToken          Cloudflare API token (required for install)
    --zoneId           Cloudflare Zone ID (required for install)
    --source           Source IP address (optional)
    --ttl              TTL for DNS record (optional)

Examples:
    cf-ddns.sh install --target host1.example.com --apiToken TOKEN --zoneId ZONE
    cf-ddns.sh uninstall --target host1.example.com
EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    COMMAND=""
    TARGET=""
    EXTRA_ARGS=""

    [ $# -eq 0 ] && show_help

    COMMAND="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            --target)
                TARGET="$2"
                shift 2
                ;;
            *)
                if [ "$COMMAND" = "install" ]; then
                    EXTRA_ARGS="$EXTRA_ARGS $1 $2"
                    shift 2
                else
                    echo "Error: Unknown argument $1"
                    exit 1
                fi
                ;;
        esac
    done

    # Validate arguments
    if [ -z "$TARGET" ]; then
        echo "Error: --target is required"
        exit 1
    fi

    if [ "$COMMAND" = "install" ] && [ -z "$EXTRA_ARGS" ]; then
        echo "Error: install command requires --apiToken and --zoneId"
        exit 1
    fi
}

# Create systemd service and timer
create_systemd_units() {
    local service_name="cf-ddns-${TARGET//[.]/-}.service"
    local timer_name="cf-ddns-${TARGET//[.]/-}.timer"
    local script_dir="$(dirname "$(readlink -f "$0")")"

    # Create service unit
    cat > "/etc/systemd/system/$service_name" << EOF
[Unit]
Description=Synchronizes DNS records for $TARGET
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$script_dir/cf-ddns-sync.sh --target $TARGET $EXTRA_ARGS

[Install]
WantedBy=multi-user.target
EOF

    # Create timer unit
    cat > "/etc/systemd/system/$timer_name" << EOF
[Unit]
Description=Keeps DNS records for $TARGET synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

    chmod 644 "/etc/systemd/system/$service_name"
    chmod 644 "/etc/systemd/system/$timer_name"
}

# Install service and timer
install_service() {
    local timer_name="cf-ddns-${TARGET//[.]/-}.timer"
    create_systemd_units
    systemctl daemon-reload
    systemctl stop "$timer_name" 2>/dev/null || true
    systemctl enable --now "$timer_name"
    echo "Service installed successfully"
}

# Uninstall service and timer
uninstall_service() {
    local service_name="cf-ddns-${TARGET//[.]/-}.service"
    local timer_name="cf-ddns-${TARGET//[.]/-}.timer"
    
    systemctl stop "$timer_name" 2>/dev/null || true
    systemctl disable "$timer_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/$service_name"
    rm -f "/etc/systemd/system/$timer_name"
    
    systemctl daemon-reload
    echo "Service uninstalled successfully"
}

# Main execution
parse_args "$@"

case "$COMMAND" in
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    *)
        echo "Error: Unknown command $COMMAND"
        exit 1
        ;;
esac
