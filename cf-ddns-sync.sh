#!/bin/bash

set -euo pipefail

# Global variables
VERBOSE=false
CACHE_DIR="/var/cache/cf-ddns"
API_URL="https://api.cloudflare.com/client/v4"

# Print error message to stderr and exit
error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Print verbose message to stderr if verbose mode is enabled
verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$1" >&2
    fi
}

# Parse command line arguments
parse_args() {
    local SOURCES=()
    local API_TOKEN=""
    local ZONE_ID=""
    local TARGET=""
    local TTL=60

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]
    --apiToken TOKEN    Cloudflare API token
    --zoneId ID        Cloudflare Zone ID
    --target HOST      Target hostname
    --source IF        Network interface (can be specified multiple times)
    --ttl TTL         TTL for DNS records (default: 60)
    -v, --verbose     Enable verbose output
    -h, --help        Show this help
EOF
                exit 0
                ;;
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
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    # Validate required arguments
    [[ -z "$API_TOKEN" ]] && error "Missing required argument: --apiToken"
    [[ -z "$ZONE_ID" ]] && error "Missing required argument: --zoneId"
    [[ -z "$TARGET" ]] && error "Missing required argument: --target"

    # Export variables for use in other functions
    export CF_API_TOKEN="$API_TOKEN"
    export CF_ZONE_ID="$ZONE_ID"
    export CF_TARGET="$TARGET"
    export CF_TTL="$TTL"
    export SOURCE_INTERFACES=("${SOURCES[@]}")
}

# Call Cloudflare API
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local response

    if [[ -n "$data" ]]; then
        response=$(curl -s -X "$method" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$API_URL$endpoint" -d "$data")
    else
        response=$(curl -s -X "$method" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            "$API_URL$endpoint")
    fi

    # Check for API errors
    if [[ "$(echo "$response" | jq -r .success)" != "true" ]]; then
        local error_code=$(echo "$response" | jq -r '.errors[0].code')
        local error_message=$(echo "$response" | jq -r '.errors[0].message')
        error "$error_message (code: $error_code)"
    fi

    echo "$response"
}

# Get public IPv4 addresses
get_public_ips() {
    local ips=()
    local ip

    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        [[ -n "$ip" ]] && ips+=("$ip") && verbose "Got IPv4 address '$ip'."
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local local_ip
            local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            [[ -z "$local_ip" ]] && continue

            ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            if [[ -n "$ip" && ! " ${ips[@]} " =~ " ${ip} " ]]; then
                ips+=("$ip")
                verbose "Got IPv4 address '$ip' for interface '$iface'."
            fi
        done
    fi

    [[ ${#ips[@]} -eq 0 ]] && error "Cannot get public IPv4 address."
    echo "${ips[@]}"
}

# Get DNS records from cache or API
get_dns_records() {
    local cache_file="$CACHE_DIR/${CF_ZONE_ID}_${CF_TARGET}.cache"
    local records

    # Create cache directory if it doesn't exist
    mkdir -p "$CACHE_DIR"

    # Try to read from cache first
    if [[ -r "$cache_file" ]]; then
        records=$(jq -r '.records' "$cache_file")
    fi

    # If cache miss or invalid, fetch from API
    if [[ -z "${records:-}" || "$records" == "null" ]]; then
        local response
        response=$(cf_api "GET" "/zones/$CF_ZONE_ID/dns_records?type=A&name=$CF_TARGET")
        records=$(echo "$response" | jq '.result')
        
        # Update cache
        jq -n --arg ts "$(date +%s)" --argjson recs "$records" \
            '{"timestamp":($ts|tonumber),"records":$recs}' > "$cache_file"
    fi

    [[ "$records" == "[]" ]] && error "Unknown host '$CF_TARGET'."
    echo "$records"
}

# Synchronize DNS records
sync_dns_records() {
    local source_ips=($1)
    local records
    records=$(get_dns_records)

    # Process each source IP
    for ip in "${source_ips[@]}"; do
        local record_id
        record_id=$(echo "$records" | jq -r ".[] | select(.content == \"$ip\") | .id")

        if [[ -n "$record_id" ]]; then
            verbose "Skipping '$CF_TARGET'."
            continue
        fi

        # Create new record
        verbose "Adding '$ip' to '$CF_TARGET'."
        cf_api "POST" "/zones/$CF_ZONE_ID/dns_records" \
            "{\"type\":\"A\",\"name\":\"$CF_TARGET\",\"content\":\"$ip\",\"ttl\":$CF_TTL}"
    done

    # Remove outdated records
    while read -r record_id ip; do
        if [[ -n "$record_id" && ! " ${source_ips[@]} " =~ " ${ip} " ]]; then
            verbose "Removing '$ip' from '$CF_TARGET'."
            cf_api "DELETE" "/zones/$CF_ZONE_ID/dns_records/$record_id"
        fi
    done < <(echo "$records" | jq -r '.[] | "\(.id) \(.content)"')
}

# Main execution
main() {
    parse_args "$@"
    local public_ips
    public_ips=$(get_public_ips)
    sync_dns_records "$public_ips"
}

main "$@"
