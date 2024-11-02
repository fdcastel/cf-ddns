#!/bin/bash

set -euo pipefail

# Initialize variables
API_TOKEN=""
ZONE_ID=""
TARGET_HOST=""
SOURCE_INTERFACES=()
TTL=60
VERBOSE=false

# Print to stderr
log_error() { echo "ERROR: $*" >&2; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then echo "$*" >&2; fi; }

# Show usage instructions
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE --target HOST [--source IFACE]... [--ttl TTL] [-v]
Update Cloudflare DNS A records with public IPv4 addresses from network interfaces.

Options:
  --apiToken TOKEN    Cloudflare API token
  --zoneId ZONE      DNS zone ID
  --target HOST      Target hostname
  --source IFACE     Network interface (can be specified multiple times)
  --ttl TTL          TTL for DNS records (default: 60)
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message
EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --apiToken) API_TOKEN="$2"; shift 2 ;;
        --zoneId) ZONE_ID="$2"; shift 2 ;;
        --target) TARGET_HOST="$2"; shift 2 ;;
        --source) SOURCE_INTERFACES+=("$2"); shift 2 ;;
        --ttl) TTL="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate required arguments
[[ -z "$API_TOKEN" ]] && { log_error "Missing required --apiToken argument"; usage; }
[[ -z "$ZONE_ID" ]] && { log_error "Missing required --zoneId argument"; usage; }
[[ -z "$TARGET_HOST" ]] && { log_error "Missing required --target argument"; usage; }

# Function to handle Cloudflare API calls
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local response
    
    if [[ -n "$data" ]]; then
        response=$(curl -s -X "$method" \
            "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data")
    else
        response=$(curl -s -X "$method" \
            "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $API_TOKEN")
    fi

    if [[ "$(echo "$response" | jq -r .success)" != "true" ]]; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        log_error "$error_message (code: $error_code)"
        exit 1
    fi

    echo "$response"
}

# Get public IPv4 addresses
get_public_ipv4() {
    local public_ips=()
    
    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        local ip
        ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        [[ -z "$ip" ]] && { log_error "Cannot get public IPv4 address"; exit 1; }
        log_verbose "Got IPv4 address '$ip'."
        public_ips+=("$ip")
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local local_ip public_ip
            local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            [[ -z "$public_ip" ]] && { log_error "Cannot get public IPv4 address"; exit 1; }
            log_verbose "Got IPv4 address '$public_ip' for interface '$iface'."
            public_ips+=("$public_ip")
        done
    fi

    echo "${public_ips[@]}"
}

# Get current DNS records
get_dns_records() {
    local response
    response=$(cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOST")
    echo "$response" | jq -r '.result'
}

# Synchronize DNS records
sync_dns_records() {
    local source_ips=($1)
    local records
    records=$(get_dns_records)
    
    [[ "$(echo "$records" | jq length)" -eq 0 ]] && { 
        log_error "Unknown host '$TARGET_HOST'"; 
        exit 1; 
    }

    # Process existing records
    echo "$records" | jq -c '.[]' | while read -r record; do
        local record_ip record_id
        record_ip=$(echo "$record" | jq -r '.content')
        record_id=$(echo "$record" | jq -r '.id')

        if [[ " ${source_ips[@]} " =~ " ${record_ip} " ]]; then
            log_verbose "Skipping '$TARGET_HOST'."
        else
            log_verbose "Removing '$record_ip' from '$TARGET_HOST'."
            cf_api DELETE "/zones/$ZONE_ID/dns_records/$record_id"
        fi
    done

    # Add new records
    for ip in "${source_ips[@]}"; do
        if ! echo "$records" | jq -e ".[] | select(.content == \"$ip\")" >/dev/null; then
            log_verbose "Adding '$ip' to '$TARGET_HOST'."
            cf_api POST "/zones/$ZONE_ID/dns_records" "{
                \"type\": \"A\",
                \"name\": \"$TARGET_HOST\",
                \"content\": \"$ip\",
                \"ttl\": $TTL
            }"
        fi
    done
}

# Main execution
public_ips=$(get_public_ipv4)
sync_dns_records "$public_ips"
