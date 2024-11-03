#!/bin/bash

set -euo pipefail

# Default TTL value
DEFAULT_TTL=60

# Variables for storing command line arguments
API_TOKEN=""
ZONE_ID=""
TARGET_HOSTNAME=""
SOURCE_INTERFACES=()
TTL=$DEFAULT_TTL
VERBOSE=false

# Function to print verbose messages
print_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$1" >&2
    fi
}

# Function to print error messages
print_error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Function to print usage
print_usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [--ttl TTL] [-v|--verbose]

Options:
  --apiToken TOKEN    Cloudflare API Token for authentication
  --zoneId ZONE_ID   DNS Zone ID for the target DNS record
  --target HOSTNAME   Hostname for the Cloudflare DNS record
  --source INTERFACE Network interface to get IPv4 address from (can be specified multiple times)
  --ttl TTL          TTL value for DNS records (default: 60)
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message
EOF
    exit 1
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
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            print_error "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[[ -z "$API_TOKEN" ]] && print_error "Missing required option: --apiToken"
[[ -z "$ZONE_ID" ]] && print_error "Missing required option: --zoneId"
[[ -z "$TARGET_HOSTNAME" ]] && print_error "Missing required option: --target"

# Function to handle Cloudflare API responses
handle_cf_response() {
    local response="$1"
    if [[ $(echo "$response" | jq -r '.success') != "true" ]]; then
        local error_code=$(echo "$response" | jq -r '.errors[0].code')
        local error_message=$(echo "$response" | jq -r '.errors[0].message')
        print_error "$error_message (code: $error_code)"
    fi
}

# Function to get public IPv4 addresses
get_public_ipv4_addresses() {
    local public_ips=()
    
    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        local public_ip
        public_ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        if [[ -n "$public_ip" ]]; then
            print_verbose "Got IPv4 address '$public_ip'."
            public_ips+=("$public_ip")
        fi
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local local_ip
            local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            
            if [[ -n "$local_ip" ]]; then
                local public_ip
                public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
                if [[ -n "$public_ip" ]]; then
                    print_verbose "Got IPv4 address '$public_ip' for interface '$iface'."
                    public_ips+=("$public_ip")
                fi
            fi
        done
    fi

    if [[ ${#public_ips[@]} -eq 0 ]]; then
        print_error "Cannot get public IPv4 address."
    fi

    echo "${public_ips[@]}"
}

# Function to get DNS records from cache or API
get_dns_records() {
    local cache_dir="/var/cache/cf-ddns"
    local cache_file="${cache_dir}/${ZONE_ID}_${TARGET_HOSTNAME}.cache"
    local current_time=$(date +%s)
    local records

    # Create cache directory if it doesn't exist
    mkdir -p "$cache_dir"

    # Try to read from cache first
    if [[ -r "$cache_file" ]]; then
        records=$(cat "$cache_file")
    fi

    # If no cache or cache is invalid, fetch from API
    if [[ -z "$records" ]]; then
        local response
        response=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOSTNAME" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json")
        
        handle_cf_response "$response"
        records=$(echo "$response" | jq -c "{timestamp:$current_time,records:.result}")
        echo "$records" > "$cache_file"
    fi

    echo "$records" | jq -r '.records[]'
}

# Function to synchronize DNS records
sync_dns_records() {
    local source_ips=($1)
    local records
    records=$(get_dns_records)

    if [[ -z "$records" ]]; then
        print_error "Unknown host '$TARGET_HOSTNAME'."
    fi

    # Process each source IP
    for ip in "${source_ips[@]}"; do
        local record_id
        record_id=$(echo "$records" | jq -r "select(.content == \"$ip\") | .id")

        if [[ -n "$record_id" ]]; then
            print_verbose "Skipping '$TARGET_HOSTNAME'."
            continue
        fi

        # Create new record
        local response
        response=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$TARGET_HOSTNAME\",\"content\":\"$ip\",\"ttl\":$TTL}")
        
        handle_cf_response "$response"
        print_verbose "Adding '$ip' to '$TARGET_HOSTNAME'."
    done

    # Remove outdated records
    while IFS= read -r record; do
        local record_ip
        local record_id
        record_ip=$(echo "$record" | jq -r '.content')
        record_id=$(echo "$record" | jq -r '.id')

        if [[ ! " ${source_ips[@]} " =~ " ${record_ip} " ]]; then
            local response
            response=$(curl -s -X DELETE \
                "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json")
            
            handle_cf_response "$response"
            print_verbose "Removing '$record_ip' from '$TARGET_HOSTNAME'."
        fi
    done < <(echo "$records" | jq -c '.')
}

# Main execution
public_ips=$(get_public_ipv4_addresses)
sync_dns_records "$public_ips"

exit 0
