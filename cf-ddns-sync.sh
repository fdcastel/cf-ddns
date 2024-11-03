#!/bin/bash
set -euo pipefail

CACHE_DIR="/var/cache/cf-ddns"
API_URL="https://api.cloudflare.com/client/v4"

# Print error message to stderr and exit
error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Print verbose message to stderr if verbose mode is enabled
verbose() {
    [[ ${VERBOSE:-0} -eq 1 ]] && echo "$1" >&2
}

# Parse command line arguments
parse_args() {
    VERBOSE=0
    TTL=60
    SOURCE_INTERFACES=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: cf-ddns-sync.sh --apiToken TOKEN --zoneId ZONE --target HOST [--source IFACE]... [--ttl TTL] [-v|--verbose]" >&2
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
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
                TARGET_HOST="$2"
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
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done

    # Validate required arguments
    [[ -z ${API_TOKEN:-} ]] && error "Missing required argument: --apiToken"
    [[ -z ${ZONE_ID:-} ]] && error "Missing required argument: --zoneId"
    [[ -z ${TARGET_HOST:-} ]] && error "Missing required argument: --target"
}

# Make API call to Cloudflare
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    response=$(curl -s -X "$method" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "$API_URL$endpoint")
    
    if [[ $(echo "$response" | jq -r '.success') != "true" ]]; then
        local error_code=$(echo "$response" | jq -r '.errors[0].code')
        local error_message=$(echo "$response" | jq -r '.errors[0].message')
        error "$error_message (code: $error_code)"
    fi
    
    echo "$response"
}

# Get public IPv4 addresses
get_public_ips() {
    local -A public_ips
    
    if [[ ${#SOURCE_INTERFACES[@]} -eq 0 ]]; then
        local ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
        [[ -n $ip ]] && public_ips["$ip"]=1 && verbose "Got IPv4 address '$ip'."
    else
        for iface in "${SOURCE_INTERFACES[@]}"; do
            local local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
            [[ -z $local_ip ]] && continue
            
            local public_ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            [[ -z $public_ip ]] && continue
            [[ -n ${public_ips["$public_ip"]:-} ]] && continue
            
            public_ips["$public_ip"]=1
            verbose "Got IPv4 address '$public_ip' for interface '$iface'."
        done
    fi
    
    [[ ${#public_ips[@]} -eq 0 ]] && error "Cannot get public IPv4 address."
    echo "${!public_ips[@]}"
}

# Cache management functions
get_cached_records() {
    local cache_file="$CACHE_DIR/$TARGET_HOST.cache"
    local ip_count="$1"
    
    if [[ -r $cache_file ]]; then
        local cached_count=$(jq '.records | length' "$cache_file")
        if [[ $cached_count -eq $ip_count ]]; then
            jq -r '.records' "$cache_file"
            return 0
        fi
    fi
    
    mkdir -p "$CACHE_DIR"
    local response=$(cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOST")
    local records=$(echo "$response" | jq '.result')
    echo "{\"timestamp\": $(date +%s), \"records\": $records}" > "$cache_file"
    echo "$records"
}

# Update cache after modifications
update_cache() {
    local response=$(cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$TARGET_HOST")
    echo "{\"timestamp\": $(date +%s), \"records\": $(echo "$response" | jq '.result')}" > "$CACHE_DIR/$TARGET_HOST.cache"
}

# Main function
main() {
    parse_args "$@"
    
    # Get public IPs
    mapfile -t source_ips < <(get_public_ips)
    
    # Get current DNS records
    records=$(get_cached_records "${#source_ips[@]}")
    [[ $(echo "$records" | jq 'length') -eq 0 ]] && error "Unknown host '$TARGET_HOST'."
    
    # Process each source IP
    for ip in "${source_ips[@]}"; do
        local record_id=$(echo "$records" | jq -r ".[] | select(.content == \"$ip\") | .id")
        if [[ -n $record_id ]]; then
            verbose "Skipping '$TARGET_HOST'."
            continue
        fi
        
        # Find record to update or create new one
        record_id=$(echo "$records" | jq -r '.[0].id')
        if [[ -n $record_id ]]; then
            verbose "Updating '$ip' in '$TARGET_HOST'."
            cf_api PUT "/zones/$ZONE_ID/dns_records/$record_id" "{\"type\":\"A\",\"name\":\"$TARGET_HOST\",\"content\":\"$ip\",\"ttl\":$TTL}"
        else
            verbose "Adding '$ip' to '$TARGET_HOST'."
            cf_api POST "/zones/$ZONE_ID/dns_records" "{\"type\":\"A\",\"name\":\"$TARGET_HOST\",\"content\":\"$ip\",\"ttl\":$TTL}"
        fi
        update_cache
    done
    
    # Remove extra records
    while read -r record_id; do
        [[ -z $record_id ]] && continue
        local ip=$(echo "$records" | jq -r ".[] | select(.id == \"$record_id\") | .content")
        verbose "Removing '$ip' from '$TARGET_HOST'."
        cf_api DELETE "/zones/$ZONE_ID/dns_records/$record_id"
        update_cache
    done < <(echo "$records" | jq -r ".[] | select(.content != $(printf '%s\n' "${source_ips[@]}" | jq -R . | jq -s .)) | .id")
}

main "$@"
