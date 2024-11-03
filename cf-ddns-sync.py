#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from typing import List, Optional, Set

def verbose_print(message: str) -> None:
    print(message, file=sys.stderr)

def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Update Cloudflare DNS A records with IPv4 addresses')
    parser.add_argument('--apiToken', required=True, help='Cloudflare API Token')
    parser.add_argument('--zoneId', required=True, help='DNS Zone ID')
    parser.add_argument('--target', required=True, help='Target hostname')
    parser.add_argument('--source', action='append', help='Network interface(s)')
    parser.add_argument('--ttl', type=int, default=60, help='TTL value (default: 60)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    return parser.parse_args()

def run_command(cmd: List[str]) -> Optional[str]:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.stdout.strip() if result.stdout else None
    except subprocess.SubprocessError:
        return None

def get_public_ipv4(iface: Optional[str], verbose: bool) -> Optional[str]:
    if iface:
        cmd = ['ip', '-4', '-oneline', 'address', 'show', iface]
        local_ip = run_command(cmd)
        if not local_ip:
            return None
        import re
        local_ip = re.search(r'(\d{1,3}\.){3}\d{1,3}', local_ip)
        if not local_ip:
            return None
        cmd = ['dig', '-b', local_ip.group(), '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.1.1.1']
    else:
        cmd = ['dig', '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.1.1.1']
    
    result = run_command(cmd)
    if result:
        ip = result.strip('"')
        if verbose:
            msg = f"Got IPv4 address '{ip}'" + (f" for interface '{iface}'." if iface else ".")
            verbose_print(msg)
        return ip
    return None

def get_cache_path(hostname: str) -> str:
    cache_dir = "/var/cache/cf-ddns"
    os.makedirs(cache_dir, exist_ok=True)
    return f"{cache_dir}/{hostname}.cache"

def read_cache(hostname: str) -> Optional[Set[str]]:
    try:
        with open(get_cache_path(hostname), 'r') as f:
            return set(line.strip() for line in f)
    except (FileNotFoundError, PermissionError):
        return None

def write_cache(hostname: str, ips: Set[str]) -> None:
    with open(get_cache_path(hostname), 'w') as f:
        for ip in sorted(ips):
            f.write(f"{ip}\n")

def cf_api_request(method: str, url: str, api_token: str, data: Optional[dict] = None) -> dict:
    headers = {
        'Authorization': f'Bearer {api_token}',
        'Content-Type': 'application/json'
    }
    request = urllib.request.Request(
        url,
        headers=headers,
        method=method,
        data=json.dumps(data).encode() if data else None
    )
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

def get_dns_records(zone_id: str, hostname: str, api_token: str) -> List[dict]:
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records"
    response = cf_api_request('GET', url, api_token)
    if not response.get('success', False):
        error = response.get('errors', [{}])[0]
        print(f"ERROR: {error.get('message')} (code: {error.get('code')})", file=sys.stderr)
        sys.exit(1)
    return [r for r in response['result'] if r['type'] == 'A' and r['name'] == hostname]

def main() -> None:
    args = get_args()
    source_ips: Set[str] = set()

    # Get public IPv4 addresses
    if args.source:
        for iface in args.source:
            ip = get_public_ipv4(iface, args.verbose)
            if ip:
                source_ips.add(ip)
    else:
        ip = get_public_ipv4(None, args.verbose)
        if ip:
            source_ips.add(ip)

    if not source_ips:
        print("ERROR: Cannot get public IPv4 address.", file=sys.stderr)
        sys.exit(1)

    # Check cache and get current DNS records
    cached_ips = read_cache(args.target)
    if (not cached_ips or
        len(cached_ips) != len(source_ips) or
        not source_ips.issubset(cached_ips)):
        records = get_dns_records(args.zoneId, args.target, args.apiToken)
        if not records:
            print(f"ERROR: Unknown host '{args.target}'.", file=sys.stderr)
            sys.exit(1)
        current_ips = {r['content'] for r in records}
    else:
        current_ips = cached_ips
        records = get_dns_records(args.zoneId, args.target, args.apiToken)

    # Synchronize DNS records
    error_occurred = False
    base_url = f"https://api.cloudflare.com/client/v4/zones/{args.zoneId}/dns_records"

    # Process additions and updates
    for ip in source_ips:
        matching_record = next((r for r in records if r['content'] == ip), None)
        if matching_record:
            if args.verbose:
                verbose_print(f"Skipping '{args.target}'.")
            continue

        existing_record = next((r for r in records if r['name'] == args.target), None)
        if existing_record:
            # Update
            if args.verbose:
                verbose_print(f"Updating '{ip}' in '{args.target}'.")
            url = f"{base_url}/{existing_record['id']}"
            data = {
                'content': ip,
                'name': args.target,
                'type': 'A',
                'ttl': args.ttl
            }
            response = cf_api_request('PUT', url, args.apiToken, data)
            if not response.get('success', False):
                error = response.get('errors', [{}])[0]
                print(f"ERROR: {error.get('message')} (code: {error.get('code')})", file=sys.stderr)
                error_occurred = True
        else:
            # Insert
            if args.verbose:
                verbose_print(f"Adding '{ip}' to '{args.target}'.")
            data = {
                'content': ip,
                'name': args.target,
                'type': 'A',
                'ttl': args.ttl
            }
            response = cf_api_request('POST', base_url, args.apiToken, data)
            if not response.get('success', False):
                error = response.get('errors', [{}])[0]
                print(f"ERROR: {error.get('message')} (code: {error.get('code')})", file=sys.stderr)
                error_occurred = True

    # Process deletions
    for record in records:
        if record['content'] not in source_ips:
            if args.verbose:
                verbose_print(f"Removing '{record['content']}' from '{args.target}'.")
            url = f"{base_url}/{record['id']}"
            response = cf_api_request('DELETE', url, args.apiToken)
            if not response.get('success', False):
                error = response.get('errors', [{}])[0]
                print(f"ERROR: {error.get('message')} (code: {error.get('code')})", file=sys.stderr)
                error_occurred = True

    # Update cache
    write_cache(args.target, source_ips)

    if error_occurred:
        sys.exit(1)

if __name__ == '__main__':
    main()


