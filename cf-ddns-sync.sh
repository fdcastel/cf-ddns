#!/bin/bash

# Global variables
VERBOSE=false

# Function to print verbose messages
log_verbose() {
    if [[ "$VERBOSE" = true ]]; then
        echo "$1"
    fi
}

# Function to print usage
print_usage() {
    cat << EOF
Usage: $0 [options]
Required options:
  --apiToken TOKEN    Cloudflare API Token
  --zoneId ZONE_ID   Cloudflare Zone ID
  --target HOSTNAME  Target hostname to update
Optional options:
  --source INTERFACE Network interface(s) to use
  -v, --verbose     Enable verbose output
  -h, --help        Show this help message
EOF
    exit 1
}

# Parse command line arguments
SOURCES=()
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
            ;;
        *)
            echo "Error: Unknown option $1"
            print_usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$API_TOKEN" || -z "$ZONE_ID" || -z "$TARGET" ]]; then
    echo "Error: Missing required arguments"
    print_usage
fi

# Function to get public IPv4 address
get_public_ipv4() {
    local interface="$1"
    local public_ip
    
    if [[ -n "$interface" ]]; then
        log_verbose "Getting public IPv4 address for interface $interface..."
        local local_ip
        local_ip=$(ip -4 -oneline address show "$interface" | 
            grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' | 
            head -n 1)
        
        if [[ -n "$local_ip" ]]; then
            public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        fi
    else
        log_verbose "Getting public IPv4 address..."
        public_ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
    fi
    
    echo "$public_ip"
}

# Function to get DNS records
get_dns_records() {
    log_verbose "Fetching current DNS records for $TARGET..."
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$TARGET" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json"
}

# Function to create DNS record
create_dns_record() {
    local ip="$1"
    log_verbose "Creating new DNS record for IP: $ip"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET\",\"content\":\"$ip\",\"ttl\":1,\"proxied\":false}"
}

# Function to update DNS record
update_dns_record() {
    local record_id="$1"
    local ip="$2"
    local current_ip="$3"
    
    if [[ "$ip" == "$current_ip" ]]; then
        log_verbose "Skipping update for IP $ip (unchanged)"
        return
    fi
    
    log_verbose "Updating DNS record $record_id with new IP: $ip"
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$TARGET\",\"content\":\"$ip\",\"ttl\":1,\"proxied\":false}"
}

# Function to delete DNS record
delete_dns_record() {
    local record_id="$1"
    log_verbose "Deleting DNS record: $record_id"
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json"
}

# Get source IPs
declare -A SOURCE_IPS
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    ip=$(get_public_ipv4)
    [[ -n "$ip" ]] && SOURCE_IPS["default"]="$ip"
else
    for interface in "${SOURCES[@]}"; do
        ip=$(get_public_ipv4 "$interface")
        [[ -n "$ip" ]] && SOURCE_IPS["$interface"]="$ip"
    done
fi

# Get current DNS records
DNS_RECORDS=$(get_dns_records)

# Extract record IDs and IPs
declare -A CURRENT_RECORDS
declare -A CURRENT_IPS
while IFS=":" read -r id ip; do
    CURRENT_RECORDS["$ip"]="$id"
    CURRENT_IPS["$id"]="$ip"
done < <(echo "$DNS_RECORDS" | jq -r '.result[] | "\(.id):\(.content)"')

# Synchronize records
for ip in "${SOURCE_IPS[@]}"; do
    if [[ -n "${CURRENT_RECORDS[$ip]}" ]]; then
        # IP exists, update record if needed
        update_dns_record "${CURRENT_RECORDS[$ip]}" "$ip" "${CURRENT_IPS[${CURRENT_RECORDS[$ip]}]}"
        unset CURRENT_RECORDS["$ip"]
    else
        # IP doesn't exist, create new record
        create_dns_record "$ip"
    fi
done

# Delete remaining records
for id in "${CURRENT_RECORDS[@]}"; do
    delete_dns_record "$id"
done

log_verbose "DNS synchronization completed"
