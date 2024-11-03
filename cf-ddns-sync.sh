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

print_usage() {
    cat >&2 <<EOF
Usage: cf-ddns-sync.sh [options]
Options:
  --apiToken TOKEN   Cloudflare API token
  --zoneId ID       DNS zone ID
  --target HOST     Target hostname
  --source IF       Network interface (can be specified multiple times)
  --ttl NUM         TTL value for DNS records (default: 60)
  -v, --verbose     Enable verbose output
  -h, --help        Show this help
EOF
    exit 1
}

verbose=0
api_token=""
zone_id=""
target_host=""
declare -a source_interfaces
ttl=60

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --apiToken) api_token="$2"; shift 2 ;;
        --zoneId) zone_id="$2"; shift 2 ;;
        --target) target_host="$2"; shift 2 ;;
        --source) source_interfaces+=("$2"); shift 2 ;;
        --ttl) ttl="$2"; shift 2 ;;
        -v|--verbose) verbose=1; shift ;;
        -h|--help) print_usage ;;
        *) echo "ERROR: Unknown option $1" >&2; print_usage ;;
    esac
done

# Validate required arguments
[[ -z "$api_token" ]] && { echo "ERROR: --apiToken is required" >&2; exit 1; }
[[ -z "$zone_id" ]] && { echo "ERROR: --zoneId is required" >&2; exit 1; }
[[ -z "$target_host" ]] && { echo "ERROR: --target is required" >&2; exit 1; }

# Function to make Cloudflare API calls
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local response
    
    if [[ -n "$data" ]]; then
        response=$(curl -s -X "$method" \
            "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" \
            -d "$data")
    else
        response=$(curl -s -X "$method" \
            "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $api_token")
    fi
    
    if [[ $(echo "$response" | jq -r .success) != "true" ]]; then
        local error_code=$(echo "$response" | jq -r '.errors[0].code')
        local error_message=$(echo "$response" | jq -r '.errors[0].message')
        echo "ERROR: $error_message (code: $error_code)." >&2
        exit 1
    fi
    
    echo "$response"
}

# Get public IPv4 addresses
declare -A public_ips
if [[ ${#source_interfaces[@]} -eq 0 ]]; then
    ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
    if [[ -n "$ip" ]]; then
        [[ $verbose -eq 1 ]] && echo "Got IPv4 address '$ip'." >&2
        public_ips["$ip"]=1
    fi
else
    for iface in "${source_interfaces[@]}"; do
        local_ip=$(ip -4 -oneline address show "$iface" | grep -oP '(?:\d{1,3}\.){3}\d{1,3}' | head -n 1)
        if [[ -n "$local_ip" ]]; then
            ip=$(dig -b "$local_ip" +short txt ch whoami.cloudflare @1.1.1.1 | tr -d '"')
            if [[ -n "$ip" && -z "${public_ips[$ip]:-}" ]]; then
                [[ $verbose -eq 1 ]] && echo "Got IPv4 address '$ip' for interface '$iface'." >&2
                public_ips["$ip"]=1
            fi
        fi
    done
fi

[[ ${#public_ips[@]} -eq 0 ]] && { echo "ERROR: Cannot get public IPv4 address." >&2; exit 1; }

# Cache management
cache_dir="/var/cache/cf-ddns"
cache_file="$cache_dir/${target_host}.cache"
mkdir -p "$cache_dir"

fetch_records=0
if [[ ! -r "$cache_file" ]]; then
    fetch_records=1
else
    cache_count=$(wc -l < "$cache_file")
    if [[ $cache_count -ne ${#public_ips[@]} ]]; then
        fetch_records=1
    else
        while read -r ip; do
            if [[ -z "${public_ips[$ip]:-}" ]]; then
                fetch_records=1
                break
            fi
        done < "$cache_file"
    fi
fi

# Get existing DNS records
if [[ $fetch_records -eq 1 ]]; then
    response=$(cf_api GET "/zones/$zone_id/dns_records?type=A&name=$target_host")
    records=$(echo "$response" | jq -r '.result')
    if [[ "$records" == "[]" ]]; then
        echo "ERROR: Unknown host '$target_host'." >&2
        exit 1
    fi
else
    records="["
    while read -r ip; do
        records="$records{\"content\":\"$ip\"},"
    done < "$cache_file"
    records="${records%,}]"
fi

# Sync records
for ip in "${!public_ips[@]}"; do
    record_id=$(echo "$records" | jq -r ".[] | select(.content == \"$ip\") | .id")
    if [[ -n "$record_id" ]]; then
        [[ $verbose -eq 1 ]] && echo "Skipping '$target_host'." >&2
    else
        [[ $verbose -eq 1 ]] && echo "Adding '$ip' to '$target_host'." >&2
        cf_api POST "/zones/$zone_id/dns_records" \
            "{\"type\":\"A\",\"name\":\"$target_host\",\"content\":\"$ip\",\"ttl\":$ttl}"
    fi
done

echo "$records" | jq -r '.[].content' | while read -r ip; do
    if [[ -z "${public_ips[$ip]:-}" ]]; then
        [[ $verbose -eq 1 ]] && echo "Removing '$ip' from '$target_host'." >&2
        record_id=$(echo "$records" | jq -r ".[] | select(.content == \"$ip\") | .id")
        cf_api DELETE "/zones/$zone_id/dns_records/$record_id"
    fi
done

# Update cache
printf "%s\n" "${!public_ips[@]}" > "$cache_file"

exit 0
