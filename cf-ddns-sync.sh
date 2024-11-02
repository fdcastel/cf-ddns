#!/bin/bash

set -euo pipefail

# Default TTL value
DEFAULT_TTL=60

# Variables to store command line arguments
API_TOKEN=""
ZONE_ID=""
TARGET_HOSTNAME=""
SOURCE_INTERFACES=()
TTL=$DEFAULT_TTL
VERBOSE=false

# Function to print verbose messages to stderr
print_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$1" >&2
    fi
}

# Function to print error messages to stderr
print_error() {
    echo "ERROR: $1" >&2
}

# Usage instructions
usage() {
    cat >&2 << EOF
Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE --target HOSTNAME [--source INTERFACE]... [--ttl TTL] [-v|--verbose]

Required arguments:
    --apiToken TOKEN     Cloudflare API token
    --zoneId ZONE       DNS Zone ID
    --target HOSTNAME   Target hostname for DNS record

Optional arguments:
    --source INTERFACE  Network interface(s) to use (can be specified multiple times)
    --ttl TTL          TTL for DNS records (default: 60)
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
            usage
            ;;
        *)
            print_error "Unknown argument: $1"
            usage
            ;;
    esac
done

# Validate required arguments
[[ -z "$API_TOKEN" ]] && print_error "Missing required argument: --apiToken" && usage
[[ -z "$ZONE_ID" ]] && print_error "Missing required argument: --zoneId" && usage
[[ -z "$TARGET_HOSTNAME" ]] && print_error "Missing required argument: --target" && usage

# Function to get public IPv4 addresses
get_public_ipv4_addresses() {
    local public_ips=()
    
    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        local ip
        ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        print_verbose "Got IPv4 address '$ip'."
        public_ips+=("$ip")
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local local_ip
            local_ip=$(ip -4 -oneline address show "$iface" | 
                grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' | 
                head -n 1)
            
            local public_ip
            public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            print_verbose "Got IPv4 address '$public_ip' for interface '$iface'."
            public_ips+=("$public_ip")
        done
    fi
    
    echo "${public_ips[@]}"
}

# Function to handle Cloudflare API responses
handle_cf_response() {
    local response="$1"
    if [[ $(echo "$response" | jq -r .success) != "true" ]]; then
        local error_code
        local error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code')
        error_message=$(echo "$response" | jq -r '.errors[0].message')
        print_error "$error_message (code: $error_code)."
        exit 1
    fi
}

# Function to get current DNS records
get_dns_records() {
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOSTNAME" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    handle_cf_response "$response"
    echo "$response"
}

# Function to create DNS record
create_dns_record() {
    local ip="$1"
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOSTNAME\",\"content\":\"$ip\",\"ttl\":$TTL}")
    handle_cf_response "$response"
    print_verbose "Adding '$ip' to '$TARGET_HOSTNAME'."
}

# Function to update DNS record
update_dns_record() {
    local record_id="$1"
    local ip="$2"
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOSTNAME\",\"content\":\"$ip\",\"ttl\":$TTL}")
    handle_cf_response "$response"
    print_verbose "Updating '$ip' in '$TARGET_HOSTNAME'."
}

# Function to delete DNS record
delete_dns_record() {
    local record_id="$1"
    local ip="$2"
    local response
    response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    handle_cf_response "$response"
    print_verbose "Removing '$ip' from '$TARGET_HOSTNAME'."
}

# Main logic
main() {
    # Get public IPv4 addresses
    IFS=" " read -r -a source_ips <<< "$(get_public_ipv4_addresses)"
    
    # Get current DNS records
    dns_records=$(get_dns_records)
    
    # Process each existing DNS record
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        
        record_id=$(echo "$record" | jq -r .id)
        record_ip=$(echo "$record" | jq -r .content)
        
        if [[ " ${source_ips[*]} " =~ " ${record_ip} " ]]; then
            print_verbose "Skipping '$TARGET_HOSTNAME'."
        else
            delete_dns_record "$record_id" "$record_ip"
        fi
    done < <(echo "$dns_records" | jq -c '.result[]')
    
    # Add new records for IPs not already in DNS
    for ip in "${source_ips[@]}"; do
        if ! echo "$dns_records" | jq -e ".result[] | select(.content == \"$ip\")" > /dev/null; then
            create_dns_record "$ip"
        fi
    done
}

main
