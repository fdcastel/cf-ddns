#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

# Display usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") COMMAND --target hostname [OPTIONS]

Commands:
    install     Install and start the cf-ddns service
    uninstall   Remove the cf-ddns service

Required arguments:
    --target    Target hostname (e.g., host1.example.com)

Options for install command:
    All additional arguments will be passed to cf-ddns-sync.sh
    Use -h or --help with cf-ddns-sync.sh to see available options

For help:
    $(basename "$0") -h | --help
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

# Generate systemd service unit content
generate_service() {
    local target_name="$1"
    shift
    local extra_args="$*"
    
    cat << EOF
[Unit]
Description=Synchronizes DNS records for ${target_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/cf-ddns-sync.sh --target ${target_name} ${extra_args}

[Install]
WantedBy=multi-user.target
EOF
}

# Generate systemd timer unit content
generate_timer() {
    local target_name="$1"
    
    cat << EOF
[Unit]
Description=Keeps DNS records for ${target_name} synchronized every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
}

# Install the service and timer
do_install() {
    local target_name="$1"
    shift
    local service_name="cf-ddns-${target_name}"
    
    # Create service unit file
    generate_service "$target_name" "$@" > "${SYSTEMD_DIR}/${service_name}.service"
    
    # Create timer unit file
    generate_timer "$target_name" > "${SYSTEMD_DIR}/${service_name}.timer"
    
    # Reload systemd and start service
    systemctl daemon-reload
    systemctl stop "${service_name}.timer" 2>/dev/null || true
    systemctl enable --now "${service_name}.timer"
    
    echo "Service installed and started successfully"
}

# Uninstall the service and timer
do_uninstall() {
    local target_name="$1"
    local service_name="cf-ddns-${target_name}"
    
    # Stop and disable service/timer
    systemctl stop "${service_name}.timer" 2>/dev/null || true
    systemctl disable "${service_name}.timer" 2>/dev/null || true
    
    # Remove unit files
    rm -f "${SYSTEMD_DIR}/${service_name}.service"
    rm -f "${SYSTEMD_DIR}/${service_name}.timer"
    
    # Reload systemd
    systemctl daemon-reload
    
    echo "Service uninstalled successfully"
}

# Main script execution
main() {
    check_root
    
    # Parse command
    if [ $# -lt 1 ]; then
        show_usage
    fi
    
    command="$1"
    shift
    
    case "$command" in
        -h|--help)
            show_usage
            ;;
        install|uninstall)
            ;;
        *)
            echo "Error: Invalid command '$command'"
            show_usage
            ;;
    esac
    
    # Parse target argument
    target_name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --target)
                shift
                target_name="$1"
                shift
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                if [ "$command" = "uninstall" ]; then
                    echo "Error: Uninstall command only accepts --target argument"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$target_name" ]; then
        echo "Error: --target argument is required"
        show_usage
    fi
    
    # Execute requested command
    case "$command" in
        install)
            do_install "$target_name" "$@"
            ;;
        uninstall)
            do_uninstall "$target_name"
            ;;
    esac
}

main "$@"
