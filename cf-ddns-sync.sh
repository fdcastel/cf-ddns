#!/bin/bash

# Error handling
set -o errexit
set -o nounset
set -o pipefail

# Logging function that only outputs to stderr when verbose mode is enabled
log_verbose() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "$1" >&2
    fi
}

# Function to get local IPv4 address for an interface
get_local_ipv4() {
    local interface="$1"
    ip -4 -oneline address show "$interface" | 
        grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' |
        head -n 1
}

# Function to get public IPv4 address
get_public_ipv4() {
    local interface="$1"
    local public_ip
    
    if [[ -n "$interface" ]]; then
        local local_ip
        local_ip=$(get_local_ipv4 "$interface")
        if [[ -n "$local_ip" ]]; then
            public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"')
            [[ -n "$public_ip" ]] && log_verbose "Got IPv4 address '$public_ip' for interface '$interface'."
        fi
    else
        public_ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"')
        [[ -n "$public_ip" ]] && log_verbose "Got IPv4 address '$public_ip'."
    fi
    echo "$public_ip"
}

# Function to get current DNS records
get_dns_records() {
    local zone_id="$1"
    local hostname="$2"
    local api_token="$3"

    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$hostname" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json"
}

# Function to create DNS record
create_dns_record() {
    local zone_id="$1"
    local hostname="$2"
    local ip="$3"
    local api_token="$4"

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"ttl\":1}" >/dev/null
}

# Function to update DNS record
update_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    local hostname="$3"
    local ip="$4"
    local api_token="$5"

    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"ttl\":1}" >/dev/null
}

# Function to delete DNS record
delete_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    local api_token="$3"

    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" >/dev/null
}

# Parse command line arguments
API_TOKEN=""
ZONE_ID=""
TARGET=""
SOURCES=()
VERBOSE=false

print_usage() {
    echo "Usage: $0 --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [-v|--verbose]" >&2
    echo "Options:" >&2
    echo "  --apiToken TOKEN    Cloudflare API token" >&2
    echo "  --zoneId ZONE_ID   Cloudflare Zone ID" >&2
    echo "  --target HOSTNAME  Target hostname" >&2
    echo "  --source INTERFACE Network interface (can be specified multiple times)" >&2
    echo "  -v, --verbose      Enable verbose output" >&2
    echo "  -h, --help         Show this help message" >&2
}

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
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
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

# Get public IPv4 addresses
declare -A SOURCE_IPS
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    ip=$(get_public_ipv4 "")
    [[ -n "$ip" ]] && SOURCE_IPS["$ip"]=1
else
    for interface in "${SOURCES[@]}"; do
        ip=$(get_public_ipv4 "$interface")
        [[ -n "$ip" ]] && SOURCE_IPS["$ip"]=1
    done
fi

# Get current DNS records
DNS_RECORDS=$(get_dns_records "$ZONE_ID" "$TARGET" "$API_TOKEN")

# Process DNS records
declare -A CURRENT_RECORDS
while IFS= read -r line; do
    record_id=$(echo "$line" | jq -r '.id')
    ip=$(echo "$line" | jq -r '.content')
    CURRENT_RECORDS["$ip"]="$record_id"
done < <(echo "$DNS_RECORDS" | jq -c '.result[]')

# Synchronize records
for ip in "${!SOURCE_IPS[@]}"; do
    if [[ -n "${CURRENT_RECORDS[$ip]:-}" ]]; then
        log_verbose "Skipping '$TARGET'."
        unset CURRENT_RECORDS["$ip"]
    else
        log_verbose "Adding '$ip' to '$TARGET'."
        create_dns_record "$ZONE_ID" "$TARGET" "$ip" "$API_TOKEN"
    fi
done

# Remove records that are no longer needed
for ip in "${!CURRENT_RECORDS[@]}"; do
    record_id="${CURRENT_RECORDS[$ip]}"
    log_verbose "Removing '$ip' from '$TARGET'."
    delete_dns_record "$ZONE_ID" "$record_id" "$API_TOKEN"
done
