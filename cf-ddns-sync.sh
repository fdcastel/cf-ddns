#!/bin/bash
set -euo pipefail

# Function to print verbose messages to stderr
print_verbose() {
    [[ "${VERBOSE:-}" == "true" ]] && echo "$1" >&2
}

# Function to print error and exit
print_error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Function to parse JSON error response
parse_cf_error() {
    local response="$1"
    local error_code=$(echo "$response" | jq -r '.errors[0].code')
    local error_message=$(echo "$response" | jq -r '.errors[0].message')
    print_error "$error_message (code: $error_code)"
}

# Function to check API response
check_cf_response() {
    local response="$1"
    if [[ $(echo "$response" | jq -r '.success') != "true" ]]; then
        parse_cf_error "$response"
    fi
}

# Function to get public IPv4 address
get_public_ipv4() {
    local interface="$1"
    local ipv4_addr
    local public_ip

    if [[ -n "$interface" ]]; then
        ipv4_addr=$(ip -4 -oneline address show "$interface" | 
            grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' |
            head -n 1)
        [[ -z "$ipv4_addr" ]] && return
        public_ip=$(dig -b "$ipv4_addr" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"')
        [[ -n "$public_ip" ]] && print_verbose "Got IPv4 address '$public_ip' for interface '$interface'."
    else
        public_ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '\"')
        [[ -n "$public_ip" ]] && print_verbose "Got IPv4 address '$public_ip'."
    fi
    [[ -n "$public_ip" ]] && echo "$public_ip"
}

# Function to get DNS records (from cache or API)
get_dns_records() {
    local zone_id="$1"
    local hostname="$2"
    local cache_dir="/var/cache/cf-ddns"
    local cache_file="${cache_dir}/${zone_id}_${hostname}.cache"
    local current_time=$(date +%s)
    local response

    # Create cache directory if it doesn't exist
    [[ ! -d "$cache_dir" ]] && mkdir -p "$cache_dir"

    # Check if cache exists and is valid
    if [[ -r "$cache_file" ]]; then
        response=$(cat "$cache_file")
    else
        response=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${hostname}" \
            -H "Authorization: Bearer ${API_TOKEN}")
        check_cf_response "$response"
        echo "{\"timestamp\":${current_time},\"records\":$(echo "$response" | jq '.result')}" > "$cache_file"
    fi
    echo "$response" | jq -r '.records'
}

# Function to update cache
update_cache() {
    local zone_id="$1"
    local hostname="$2"
    local cache_dir="/var/cache/cf-ddns"
    local cache_file="${cache_dir}/${zone_id}_${hostname}.cache"
    local current_time=$(date +%s)
    local response

    response=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${hostname}" \
        -H "Authorization: Bearer ${API_TOKEN}")
    check_cf_response "$response"
    echo "{\"timestamp\":${current_time},\"records\":$(echo "$response" | jq '.result')}" > "$cache_file"
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
            echo "  --zoneId ID        Cloudflare Zone ID" >&2
            echo "  --target HOST      Target hostname" >&2
            echo "  --source IFACE     Network interface (can be specified multiple times)" >&2
            echo "  --ttl VALUE        TTL value (default: 60)" >&2
            echo "  -v, --verbose      Enable verbose output" >&2
            echo "  -h, --help         Show this help" >&2
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[[ -z "${API_TOKEN:-}" ]] && print_error "Missing required option: --apiToken"
[[ -z "${ZONE_ID:-}" ]] && print_error "Missing required option: --zoneId"
[[ -z "${TARGET:-}" ]] && print_error "Missing required option: --target"
TTL="${TTL:-60}"

# Get public IPv4 addresses
declare -A IP_ADDRESSES
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    ip=$(get_public_ipv4 "")
    [[ -n "$ip" ]] && IP_ADDRESSES["$ip"]=1
else
    for interface in "${SOURCES[@]}"; do
        ip=$(get_public_ipv4 "$interface")
        [[ -n "$ip" ]] && IP_ADDRESSES["$ip"]=1
    done
fi

[[ ${#IP_ADDRESSES[@]} -eq 0 ]] && print_error "Cannot get public IPv4 address."

# Get current DNS records
records=$(get_dns_records "$ZONE_ID" "$TARGET")
[[ -z "$records" ]] && print_error "Unknown host '$TARGET'."

# Process each IP address
for ip in "${!IP_ADDRESSES[@]}"; do
    record=$(echo "$records" | jq -r ".[] | select(.content==\"$ip\")")
    if [[ -n "$record" ]]; then
        print_verbose "Skipping '$TARGET'."
        continue
    fi

    # Find record with different IP to update
    record_to_update=$(echo "$records" | jq -r '.[] | select(.content!="'"$ip"'") | first')
    if [[ -n "$record_to_update" ]]; then
        record_id=$(echo "$record_to_update" | jq -r '.id')
        print_verbose "Updating '$ip' in '$TARGET'."
        response=$(curl -s -X PUT \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${TARGET}\",\"content\":\"${ip}\",\"ttl\":${TTL}}")
        check_cf_response "$response"
    else
        print_verbose "Adding '$ip' to '$TARGET'."
        response=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${TARGET}\",\"content\":\"${ip}\",\"ttl\":${TTL}}")
        check_cf_response "$response"
    fi
    update_cache "$ZONE_ID" "$TARGET"
done

# Remove extra records
for record in $(echo "$records" | jq -c '.[]'); do
    ip=$(echo "$record" | jq -r '.content')
    if [[ -z "${IP_ADDRESSES[$ip]:-}" ]]; then
        record_id=$(echo "$record" | jq -r '.id')
        print_verbose "Removing '$ip' from '$TARGET'."
        response=$(curl -s -X DELETE \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}")
        check_cf_response "$response"
        update_cache "$ZONE_ID" "$TARGET"
    fi
done

exit 0
