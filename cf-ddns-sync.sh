#!/bin/bash

set -euo pipefail

# Global variables for storing arguments
API_TOKEN=""
ZONE_ID=""
TARGET_HOSTNAME=""
SOURCE_INTERFACES=()
TTL=60
VERBOSE=0

# Helper function for verbose logging
log_verbose() {
    [[ $VERBOSE -eq 1 ]] && echo "$1" >&2
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --apiToken)
                API_TOKEN="$2"
                shift 2
                ;;
            --zoneId)
                ZONE_ID="$2"
                shift 2
                ;;
            --target)
                TARGET_HOSTNAME="$2"
                shift 2
                ;;
            --source)
                SOURCE_INTERFACES+=("$2")
                shift 2
                ;;
            --ttl)
                TTL="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                echo "Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE --target HOSTNAME [--source INTERFACE]... [--ttl TTL] [-v]" >&2
                exit 0
                ;;
            *)
                echo "Invalid argument: $1" >&2
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    [[ -z "$API_TOKEN" ]] && echo "ERROR: --apiToken is required" >&2 && exit 1
    [[ -z "$ZONE_ID" ]] && echo "ERROR: --zoneId is required" >&2 && exit 1
    [[ -z "$TARGET_HOSTNAME" ]] && echo "ERROR: --target is required" >&2 && exit 1
}

# Get public IPv4 addresses
get_public_ipv4_addresses() {
    local public_ips=()
    local ip_cmd

    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        if [[ -n "$ip" ]]; then
            log_verbose "Got IPv4 address '$ip'."
            public_ips+=("$ip")
        fi
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            if [[ -n "$local_ip" ]]; then
                ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
                if [[ -n "$ip" ]] && [[ ! " ${public_ips[@]} " =~ " ${ip} " ]]; then
                    log_verbose "Got IPv4 address '$ip' for interface '$iface'."
                    public_ips+=("$ip")
                fi
            fi
        done
    fi

    if [[ ${#public_ips[@]} -eq 0 ]]; then
        echo "ERROR: Cannot get public IPv4 address." >&2
        exit 1
    fi

    printf '%s\n' "${public_ips[@]}"
}

# Cache handling functions
get_cache_file() {
    echo "/var/cache/cf-ddns/${TARGET_HOSTNAME}.cache"
}

read_cache() {
    local cache_file
    cache_file=$(get_cache_file)
    
    if [[ -r "$cache_file" ]]; then
        cat "$cache_file"
    fi
}

write_cache() {
    local cache_file
    cache_file=$(get_cache_file)
    mkdir -p "$(dirname "$cache_file")"
    printf '%s\n' "$@" > "$cache_file"
}

# Cloudflare API functions
get_dns_records() {
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOSTNAME" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    
    if ! echo "$response" | jq -e '.success' >/dev/null; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        echo "ERROR: $error_message (code: $error_code)." >&2
        exit 1
    fi

    echo "$response" | jq -r '.result[] | .id + " " + .content'
}

create_dns_record() {
    local ip=$1
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOSTNAME\",\"content\":\"$ip\",\"ttl\":$TTL}")
    
    if ! echo "$response" | jq -e '.success' >/dev/null; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        echo "ERROR: $error_message (code: $error_code)." >&2
        return 1
    fi
}

update_dns_record() {
    local record_id=$1
    local ip=$2
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOSTNAME\",\"content\":\"$ip\",\"ttl\":$TTL}")
    
    if ! echo "$response" | jq -e '.success' >/dev/null; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        echo "ERROR: $error_message (code: $error_code)." >&2
        return 1
    fi
}

delete_dns_record() {
    local record_id=$1
    local response
    response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    
    if ! echo "$response" | jq -e '.success' >/dev/null; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        echo "ERROR: $error_message (code: $error_code)." >&2
        return 1
    fi
}

# Main synchronization function
sync_dns_records() {
    local public_ips=()
    local current_records=()
    local exit_code=0
    
    # Get public IPs
    mapfile -t public_ips < <(get_public_ipv4_addresses)
    
    # Check cache validity
    local cache_valid=1
    local cached_ips
    mapfile -t cached_ips < <(read_cache)
    
    if [[ ${#cached_ips[@]} -ne ${#public_ips[@]} ]]; then
        cache_valid=0
    else
        for ip in "${public_ips[@]}"; do
            if [[ ! " ${cached_ips[*]} " =~ " ${ip} " ]]; then
                cache_valid=0
                break
            fi
        done
    fi
    
    # Get current records
    if [[ $cache_valid -eq 0 ]]; then
        mapfile -t current_records < <(get_dns_records)
        if [[ ${#current_records[@]} -eq 0 ]]; then
            echo "ERROR: Unknown host '$TARGET_HOSTNAME'." >&2
            exit 1
        fi
    else
        current_records=("${cached_ips[@]}")
    fi

    # Process each public IP
    local current_ips=()
    local current_ids=()
    for record in "${current_records[@]}"; do
        local id content
        read -r id content <<< "$record"
        current_ips+=("$content")
        current_ids+=("$id")
    done

    # Synchronize records
    for ip in "${public_ips[@]}"; do
        if [[ " ${current_ips[*]} " =~ " ${ip} " ]]; then
            log_verbose "Skipping '$TARGET_HOSTNAME'."
            continue
        fi
        
        log_verbose "Adding '$ip' to '$TARGET_HOSTNAME'."
        if ! create_dns_record "$ip"; then
            exit_code=1
        fi
    done

    # Remove outdated records
    for i in "${!current_ips[@]}"; do
        local ip=${current_ips[$i]}
        local id=${current_ids[$i]}
        
        if [[ ! " ${public_ips[*]} " =~ " ${ip} " ]]; then
            log_verbose "Removing '$ip' from '$TARGET_HOSTNAME'."
            if ! delete_dns_record "$id"; then
                exit_code=1
            fi
        fi
    done

    # Update cache
    write_cache "${public_ips[@]}"
    
    return $exit_code
}

# Main execution
parse_args "$@"
sync_dns_records
