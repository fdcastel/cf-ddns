#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

print_usage() {
    cat << EOF
Usage: $(basename "$0") COMMAND [OPTIONS]

Commands:
    install     Install cf-ddns service for a target host
    uninstall   Uninstall cf-ddns service for a target host

Options:
    -h, --help              Show this help message
    --target HOST           Target hostname (required)
    --apiToken TOKEN        Cloudflare API token (required for install)
    --zoneId ID            Cloudflare Zone ID (required for install)
    --source SOURCE        Source IP method (optional)
    --ttl TTL             TTL value (optional)
EOF
    exit 1
}

create_service_file() {
    local target="$1"
    shift
    local args="$*"
    
    cat > "/etc/systemd/system/cf-ddns-${target}.service" << EOF
[Unit]
Description=Synchronizes DNS records for ${target}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/cf-ddns-sync.sh ${args}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=cf-ddns-${target}

[Install]
WantedBy=multi-user.target
EOF
}

create_timer_file() {
    local target="$1"
    
    cat > "/etc/systemd/system/cf-ddns-${target}.timer" << EOF
[Unit]
Description=Keeps DNS records for ${target} synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
}

install_service() {
    local target="$1"
    shift
    local args="$*"

    create_service_file "$target" "$args"
    create_timer_file "$target"
    
    systemctl daemon-reload
    systemctl stop "cf-ddns-${target}.timer" 2>/devnull || true
    systemctl enable --now "cf-ddns-${target}.timer"
}

uninstall_service() {
    local target="$1"
    
    systemctl stop "cf-ddns-${target}.timer" 2>/dev/null || true
    systemctl disable "cf-ddns-${target}.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/cf-ddns-${target}.timer"
    rm -f "/etc/systemd/system/cf-ddns-${target}.service"
    systemctl daemon-reload
}

# Parse command line arguments
command=""
target=""
api_token=""
zone_id=""
extra_args=""

while [[ $# -gt 0 ]]; do
    case $1 in
        install|uninstall)
            command="$1"
            shift
            ;;
        --target)
            target="$2"
            shift 2
            ;;
        --apiToken)
            api_token="$2"
            extra_args="$extra_args $1 $2"
            shift 2
            ;;
        --zoneId)
            zone_id="$2"
            extra_args="$extra_args $1 $2"
            shift 2
            ;;
        --source|--ttl)
            extra_args="$extra_args $1 $2"
            shift 2
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Error: Unknown argument $1"
            print_usage
            ;;
    esac
done

# Validate arguments
[[ -z "$command" ]] && { echo "Error: Command required"; print_usage; }
[[ -z "$target" ]] && { echo "Error: --target required"; print_usage; }

if [[ "$command" == "install" ]]; then
    [[ -z "$api_token" ]] && { echo "Error: --apiToken required for install"; print_usage; }
    [[ -z "$zone_id" ]] && { echo "Error: --zoneId required for install"; print_usage; }
    install_service "$target" "$extra_args"
else
    uninstall_service "$target"
fi
