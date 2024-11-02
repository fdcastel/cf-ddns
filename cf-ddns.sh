#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

# Display usage information
show_usage() {
    cat << EOF
Usage: cf-ddns.sh COMMAND --target TARGET [OPTIONS]

Commands:
    install     Install cf-ddns service
    uninstall   Uninstall cf-ddns service

Required arguments:
    --target    Target hostname (e.g., host1.example.com)

Options for install command:
    --apiToken  Cloudflare API token
    --zoneId    Cloudflare Zone ID
    --source    Source for IP address lookup (optional)
    --ttl       TTL value for DNS record (optional)
    -h, --help  Show this help message
EOF
    exit 1
}

# Validate root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
}

validate_arguments() {
    if [ $# -lt 2 ]; then
        show_usage
    fi

    command="$1"
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --target)
                target="$2"
                shift 2
                ;;
            --apiToken)
                api_token="$2"
                shift 2
                ;;
            --zoneId)
                zone_id="$2"
                shift 2
                ;;
            --source)
                source_arg="$2"
                shift 2
                ;;
            --ttl)
                ttl="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                echo "Error: Unknown argument $1"
                show_usage
                ;;
        esac
    done

    if [ -z "${target:-}" ]; then
        echo "Error: --target is required"
        show_usage
    fi

    if [ "$command" = "install" ]; then
        if [ -z "${api_token:-}" ] || [ -z "${zone_id:-}" ]; then
            echo "Error: --apiToken and --zoneId are required for install command"
            show_usage
        fi
    fi
}

create_service_file() {
    local service_name="cf-ddns-$target"
    local args="--target $target --apiToken $api_token --zoneId $zone_id"
    
    if [ -n "${source_arg:-}" ]; then
        args="$args --source $source_arg"
    fi
    if [ -n "${ttl:-}" ]; then
        args="$args --ttl $ttl"
    fi

    cat > "/etc/systemd/system/$service_name.service" << EOF
[Unit]
Description=Synchronizes DNS records for $target
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/cf-ddns/cf-ddns-sync.sh $args

[Install]
WantedBy=multi-user.target
EOF
}

create_timer_file() {
    local service_name="cf-ddns-$target"
    
    cat > "/etc/systemd/system/$service_name.timer" << EOF
[Unit]
Description=Keeps DNS records for $target synchronized every minute
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
    local service_name="cf-ddns-$target"
    
    create_service_file
    create_timer_file
    
    systemctl daemon-reload
    systemctl stop "$service_name.timer" 2>/dev/null || true
    systemctl enable --now "$service_name.timer"
    
    echo "Service installed and started successfully"
}

uninstall_service() {
    local service_name="cf-ddns-$target"
    
    systemctl stop "$service_name.timer" 2>/dev/null || true
    systemctl disable "$service_name.timer" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/$service_name.service"
    rm -f "/etc/systemd/system/$service_name.timer"
    
    systemctl daemon-reload
    
    echo "Service uninstalled successfully"
}

# Main script execution
main() {
    check_root
    
    validate_arguments "$@"
    
    case "$command" in
        install)
            install_service
            ;;
        uninstall)
            uninstall_service
            ;;
        *)
            echo "Error: Unknown command $command"
            show_usage
            ;;
    esac
}

main "$@"
