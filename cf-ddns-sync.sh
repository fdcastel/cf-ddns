#!/bin/bash

# Exit on error
set -e

# Initialize variables
API_TOKEN=""
ZONE_ID=""
TARGET_HOST=""
SOURCE_INTERFACES=()
VERBOSE=false

# Function to print to stderr if verbose mode is enabled
log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$1" >&2
    fi
}

# Function to print usage
print_usage() {
    cat <<EOF
Usage: $(basename "$0") --apiToken TOKEN --zoneId ZONE_ID --target HOST [--source INTERFACE]... [-v|--verbose]

Options:
  --apiToken TOKEN     Cloudflare API token
  --zoneId ZONE_ID    DNS Zone ID
  --target HOST       Target hostname
  --source INTERFACE  Network interface (can be specified multiple times)
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message
EOF
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
            TARGET_HOST="$2"
            shift 2
            ;;
        --source)
            SOURCE_INTERFACES+=("$2")
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
            echo "Unknown option: $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$API_TOKEN" || -z "$ZONE_ID" || -z "$TARGET_HOST" ]]; then
    echo "Error: Missing required arguments" >&2
    print_usage
    exit 1
fi

# Function to get public IPv4 address for an interface
get_public_ipv4() {
    local interface=$1
    if [[ -n "$interface" ]]; then
        log_verbose "Getting public IPv4 address for interface $interface..."
        local local_ip
        local_ip=$(ip -4 -oneline address show "$interface" | 
            grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' | 
            head -n 1)
        dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"'
    else
        log_verbose "Getting public IPv4 address..."
        dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"'
    fi
}

# Function to get current DNS A records
get_dns_records() {
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOST" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json"
}

# Function to create DNS A record
create_dns_record() {
    local ip=$1
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOST\",\"content\":\"$ip\",\"ttl\":1}"
}

# Function to update DNS A record
update_dns_record() {
    local record_id=$1
    local ip=$2
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET_HOST\",\"content\":\"$ip\",\"ttl\":1}"
}

# Function to delete DNS A record
delete_dns_record() {
    local record_id=$1
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json"
}

# Get public IPv4 addresses
declare -A source_ips
if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
    ip=$(get_public_ipv4)
    [[ -n "$ip" ]] && source_ips["$ip"]=1
else
    for interface in "${SOURCE_INTERFACES[@]}"; do
        ip=$(get_public_ipv4 "$interface")
        [[ -n "$ip" ]] && source_ips["$ip"]=1
    done
fi

# Get current DNS records
records_response=$(get_dns_records)
current_records=$(echo "$records_response" | jq -r '.result[] | {id: .id, ip: .content}')

# Process each source IP
for ip in "${!source_ips[@]}"; do
    record_id=$(echo "$current_records" | jq -r "select(.ip == \"$ip\") | .id")
    if [[ -z "$record_id" ]]; then
        log_verbose "Creating new DNS record for IP: $ip"
        create_dns_record "$ip"
    else
        log_verbose "IP $ip already exists in DNS records"
    fi
done

# Remove obsolete records
echo "$current_records" | jq -c '.[]' | while read -r record; do
    ip=$(echo "$record" | jq -r '.ip')
    if [[ -z "${source_ips[$ip]}" ]]; then
        record_id=$(echo "$record" | jq -r '.id')
        log_verbose "Deleting obsolete DNS record for IP: $ip"
        delete_dns_record "$record_id"
    fi
done
