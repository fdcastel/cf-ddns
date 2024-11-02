#!/bin/bash

set -euo pipefail

VERBOSE=false
CACHE_DIR="/var/cache/cf-ddns"
TTL=60

# Print to stderr if verbose mode is enabled
log_verbose() {
    if [[ "$VERBOSE" = true ]]; then
        echo "$1" >&2
    fi
}

# Print error and exit
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Handle Cloudflare API response
handle_cf_response() {
    local response=$1
    if [[ $(echo "$response" | jq -r '.success') != "true" ]]; then
        local error_code=$(echo "$response" | jq -r '.errors[0].code')
        local error_message=$(echo "$response" | jq -r '.errors[0].message')
        error_exit "$error_message (code: $error_code)"
    fi
}

# Get public IPv4 addresses
get_public_ipv4() {
    local interfaces=("$@")
    local public_ips=()
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        local ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        [[ -z "$ip" ]] && error_exit "Cannot get public IPv4 address."
        log_verbose "Got IPv4 address '$ip'."
        public_ips+=("$ip")
    else
        for iface in "${interfaces[@]}"; do
            local local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            local public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            [[ -z "$public_ip" ]] && error_exit "Cannot get public IPv4 address."
            log_verbose "Got IPv4 address '$public_ip' for interface '$iface'."
            public_ips+=("$public_ip")
        done
    fi
    echo "${public_ips[@]}"
}

# Get DNS records from cache or API
get_dns_records() {
    local zone_id=$1
    local hostname=$2
    local cache_file="$CACHE_DIR/${zone_id}_${hostname}.cache"
    local current_time=$(date +%s)
    
    mkdir -p "$CACHE_DIR"
    
    if [[ -r "$cache_file" ]]; then
        local cached_records=$(cat "$cache_file")
    else
        local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$hostname" \
            -H "Authorization: Bearer $API_TOKEN")
        handle_cf_response "$response"
        local records=$(echo "$response" | jq -c '.result')
        echo "{\"timestamp\": $current_time, \"records\": $records}" > "$cache_file"
        cached_records=$(cat "$cache_file")
    fi
    
    local records=$(echo "$cached_records" | jq -r '.records')
    [[ "$records" == "[]" ]] && error_exit "Unknown host '$hostname'."
    echo "$records"
}

# Sync DNS records
sync_dns_records() {
    local zone_id=$1
    local hostname=$2
    shift 2
    local source_ips=("$@")
    
    local records=$(get_dns_records "$zone_id" "$hostname")
    
    # Process each source IP
    for ip in "${source_ips[@]}"; do
        local record_id=$(echo "$records" | jq -r ".[] | select(.content == \"$ip\") | .id")
        if [[ -n "$record_id" ]]; then
            log_verbose "Skipping '$hostname'."
            continue
        fi
        
        # Create new record
        local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"ttl\":$TTL}")
        handle_cf_response "$response"
        log_verbose "Adding '$ip' to '$hostname'."
    done
    
    # Delete records not in source_ips
    while IFS= read -r record; do
        local record_ip=$(echo "$record" | jq -r '.content')
        if [[ ! " ${source_ips[@]} " =~ " ${record_ip} " ]]; then
            local record_id=$(echo "$record" | jq -r '.id')
            local response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                -H "Authorization: Bearer $API_TOKEN")
            handle_cf_response "$response"
            log_verbose "Removing '$record_ip' from '$hostname'."
        fi
    done < <(echo "$records" | jq -c '.[]')
}

# Parse command line arguments
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
            TARGET="$2"
            shift 2
            ;;
        --source)
            SOURCES+=("$2")
            shift 2
            ;;
        --ttl)
            TTL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: cf-ddns-sync.sh [OPTIONS]" >&2
            echo "Options:" >&2
            echo "  --apiToken TOKEN    Cloudflare API token" >&2
            echo "  --zoneId ID        DNS zone ID" >&2
            echo "  --target HOST      Target hostname" >&2
            echo "  --source IFACE     Network interface (can be specified multiple times)" >&2
            echo "  --ttl VALUE        TTL for DNS records (default: 60)" >&2
            echo "  -v, --verbose      Enable verbose output" >&2
            echo "  -h, --help         Show this help" >&2
            exit 0
            ;;
        *)
            error_exit "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[[ -z "${API_TOKEN:-}" ]] && error_exit "Missing required option: --apiToken"
[[ -z "${ZONE_ID:-}" ]] && error_exit "Missing required option: --zoneId"
[[ -z "${TARGET:-}" ]] && error_exit "Missing required option: --target"

# Get public IPs and sync DNS records
PUBLIC_IPS=($(get_public_ipv4 "${SOURCES[@]:-}"))
sync_dns_records "$ZONE_ID" "$TARGET" "${PUBLIC_IPS[@]}"
