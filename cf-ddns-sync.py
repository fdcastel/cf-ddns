#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

def verbose_print(message):
    if args.verbose:
        print(message, file=sys.stderr)

def get_interface_ips(interfaces):
    ips = set()
    
    if not interfaces:
        result = subprocess.run(
            ['dig', '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.1.1.1'],
            capture_output=True, text=True
        )
        if result.stdout:
            ip = result.stdout.strip().strip('"')
            ips.add(ip)
            verbose_print(f"Got IPv4 address '{ip}'.")
        return sorted(list(ips))
    
    for iface in interfaces:
        # Get local IPv4
        result = subprocess.run(
            f"ip -4 -oneline address show {iface} | grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\\d|[1-9]|)\\d)\\.?\\b){{4}}' | head -n 1",
            shell=True, capture_output=True, text=True
        )
        if not result.stdout:
            continue
        
        local_ip = result.stdout.strip()
        
        # Get public IPv4
        result = subprocess.run(
            ['dig', '-b', local_ip, '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.1.1.1'],
            capture_output=True, text=True
        )
        if result.stdout:
            ip = result.stdout.strip().strip('"')
            if ip not in ips:
                ips.add(ip)
                verbose_print(f"Got IPv4 address '{ip}' for interface '{iface}'.")
    
    return sorted(list(ips))

def get_cached_records(hostname):
    cache_file = f"/var/cache/cf-ddns/{hostname}.cache"
    try:
        with open(cache_file, 'r') as f:
            cache = json.load(f)
            return cache['timestamp'], sorted(cache['records'], key=lambda x: x['content'])
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return None, None

def update_cache(hostname, records):
    cache_dir = "/var/cache/cf-ddns"
    os.makedirs(cache_dir, exist_ok=True)
    
    cache_data = {
        'timestamp': int(time.time()),
        'records': records
    }
    
    with open(f"{cache_dir}/{hostname}.cache", 'w') as f:
        json.dump(cache_data, f)

def cf_api_request(method, path, data=None):
    url = f"https://api.cloudflare.com/client/v4/{path}"
    headers = {
        'Authorization': f'Bearer {args.apiToken}',
        'Content-Type': 'application/json'
    }
    
    request = urllib.request.Request(
        url, 
        data=json.dumps(data).encode() if data else None,
        headers=headers,
        method=method
    )
    
    try:
        with urllib.request.urlopen(request) as response:
            result = json.loads(response.read())
            if not result['success']:
                error = result['errors'][0]
                print(f"ERROR: {error['message']} (code: {error['code']}).", file=sys.stderr)
                sys.exit(1)
            return result['result']
    except urllib.error.URLError as e:
        print(f"ERROR: API request failed - {str(e)}", file=sys.stderr)
        sys.exit(1)

def get_dns_records(hostname):
    records = cf_api_request('GET', f'zones/{args.zoneId}/dns_records')
    return [r for r in records if r['type'] == 'A' and r['name'] == hostname]

def sync_dns_records(source_ips, target_records):
    current_ips = {record['content']: record for record in target_records}
    new_ips = set(source_ips)
    
    # Process existing records
    for record in target_records:
        ip = record['content']
        if ip in new_ips:
            if record['ttl'] == args.ttl:
                verbose_print(f"Skipping '{record['name']}'.")
            else:
                verbose_print(f"Updating '{ip}' in '{record['name']}'.")
                cf_api_request('PUT', f'zones/{args.zoneId}/dns_records/{record["id"]}', {
                    'type': 'A',
                    'name': record['name'],
                    'content': ip,
                    'ttl': args.ttl
                })
        else:
            verbose_print(f"Removing '{ip}' from '{record['name']}'.")
            cf_api_request('DELETE', f'zones/{args.zoneId}/dns_records/{record["id"]}')
    
    # Add new records
    for ip in new_ips - current_ips.keys():
        verbose_print(f"Adding '{ip}' to '{args.target}'.")
        cf_api_request('POST', f'zones/{args.zoneId}/dns_records', {
            'type': 'A',
            'name': args.target,
            'content': ip,
            'ttl': args.ttl
        })

def main():
    # Get source IPs
    source_ips = get_interface_ips(args.source)
    if not source_ips:
        print("ERROR: Cannot get public IPv4 address.", file=sys.stderr)
        sys.exit(1)
    
    # Get target records
    timestamp, cached_records = get_cached_records(args.target)
    
    need_refresh = True
    if cached_records:
        cached_ips = {r['content'] for r in cached_records}
        if len(cached_ips) == len(source_ips) and all(ip in cached_ips for ip in source_ips):
            need_refresh = False
    
    if need_refresh:
        target_records = sorted(get_dns_records(args.target), key=lambda x: x['content'])
        verbose_print(f"DNS A records for '{args.target}' = {[r['content'] for r in target_records]}")
    else:
        target_records = cached_records
        verbose_print(f"DNS A records for '{args.target}' = {[r['content'] for r in target_records]} (Cached)")
    
    if not target_records:
        print(f"ERROR: Unknown host '{args.target}'.", file=sys.stderr)
        sys.exit(1)
    
    # Sync records
    sync_dns_records(source_ips, target_records)
    
    # Update cache with fresh records, sorted by IP
    new_records = sorted(get_dns_records(args.target), key=lambda x: x['content'])
    update_cache(args.target, new_records)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Update Cloudflare DNS A records with IPv4 addresses from network interfaces.')
    parser.add_argument('--apiToken', required=True, help='Cloudflare API Token')
    parser.add_argument('--zoneId', required=True, help='DNS Zone ID')
    parser.add_argument('--target', required=True, help='Target hostname')
    parser.add_argument('--source', action='append', help='Source network interface')
    parser.add_argument('--ttl', type=int, default=60, help='TTL for DNS records (default: 60)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    
    args = parser.parse_args()
    main()


