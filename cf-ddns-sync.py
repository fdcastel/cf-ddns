#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from typing import List, Dict, Optional

class CloudflareDDNS:
    def __init__(self, api_token: str, zone_id: str, hostname: str, ttl: int, verbose: bool):
        self.api_token = api_token
        self.zone_id = zone_id
        self.hostname = hostname
        self.ttl = ttl
        self.verbose = verbose
        self.cache_dir = "/var/cache/cf-ddns"
        self.cache_file = f"{self.cache_dir}/{hostname}.cache"

    def log_verbose(self, message: str) -> None:
        if self.verbose:
            print(message, file=sys.stderr)

    def get_public_ipv4_addresses(self, interfaces: List[str]) -> List[str]:
        addresses = set()

        if not interfaces:
            # No interfaces specified, get single public IP
            output = self._run_dig_command()
            if output:
                addresses.add(output)
                self.log_verbose(f"Got IPv4 address '{output}'.")
        else:
            for iface in interfaces:
                local_ip = self._get_local_ipv4(iface)
                if not local_ip:
                    continue
                
                public_ip = self._run_dig_command(local_ip)
                if public_ip and public_ip not in addresses:
                    addresses.add(public_ip)
                    self.log_verbose(f"Got IPv4 address '{public_ip}' for interface '{iface}'.")

        if not addresses:
            print("ERROR: Cannot get public IPv4 address.", file=sys.stderr)
            sys.exit(1)

        return sorted(list(addresses))

    def _get_local_ipv4(self, interface: str) -> Optional[str]:
        try:
            output = subprocess.check_output(["ip", "-4", "-oneline", "address", "show", interface],
                                          text=True)
            match = re.search(r'((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}', output)
            return match.group(0) if match else None
        except subprocess.CalledProcessError:
            return None

    def _run_dig_command(self, local_ip: str = None) -> Optional[str]:
        cmd = ["dig", "+short", "txt", "ch", "whoami.cloudflare", "@1.1.1.1"]
        if local_ip:
            cmd.insert(1, f"-b{local_ip}")
        
        try:
            output = subprocess.check_output(cmd, text=True).strip()
            return output.strip('"') if output else None
        except subprocess.CalledProcessError:
            return None

    def get_dns_records(self, source_ips: List[str]) -> List[Dict]:
        cached_records = self._read_cache()
        
        if self._should_refresh_cache(cached_records, source_ips):
            records = self._fetch_dns_records()
            self._write_cache(records)
            self.log_verbose(f"DNS A records for '{self.hostname}' = {[r['content'] for r in records]}")
        else:
            self.log_verbose(f"DNS A records for '{self.hostname}' = {[r['content'] for r in cached_records['records']]} (Cached)")
            records = cached_records['records']

        return sorted(records, key=lambda x: x['content'])

    def _read_cache(self) -> Optional[Dict]:
        try:
            with open(self.cache_file, 'r') as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def _write_cache(self, records: List[Dict]) -> None:
        os.makedirs(self.cache_dir, exist_ok=True)
        cache_data = {
            'timestamp': int(time.time()),
            'records': records
        }
        with open(self.cache_file, 'w') as f:
            json.dump(cache_data, f)

    def _should_refresh_cache(self, cache: Optional[Dict], source_ips: List[str]) -> bool:
        if not cache or not cache.get('records'):
            return True
        
        cached_ips = {r['content'] for r in cache['records']}
        return len(source_ips) != len(cached_ips) or any(ip not in cached_ips for ip in source_ips)

    def _fetch_dns_records(self) -> List[Dict]:
        url = f"https://api.cloudflare.com/client/v4/zones/{self.zone_id}/dns_records?type=A&name={self.hostname}"
        req = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {self.api_token}',
            'Content-Type': 'application/json'
        })
        
        try:
            with urllib.request.urlopen(req) as response:
                data = json.loads(response.read())
                if not data['success']:
                    self._handle_api_error(data)
                return data['result']
        except urllib.error.URLError as e:
            print(f"ERROR: API request failed: {str(e)}", file=sys.stderr)
            sys.exit(1)

    def sync_records(self, source_ips: List[str], target_records: List[Dict]) -> None:
        existing_ips = {record['content']: record for record in target_records}
        
        # Handle create and update
        for ip in source_ips:
            if ip in existing_ips:
                record = existing_ips[ip]
                if record.get('ttl') != self.ttl:
                    self._update_record(record['id'], ip)
                else:
                    self.log_verbose(f"Skipping '{self.hostname}'.")
            else:
                self._create_record(ip)

        # Handle delete
        for ip, record in existing_ips.items():
            if ip not in source_ips:
                self._delete_record(record['id'], ip)

        # Refresh cache after modifications
        updated_records = self._fetch_dns_records()
        self._write_cache(updated_records)

    def _create_record(self, ip: str) -> None:
        self.log_verbose(f"Adding '{ip}' to '{self.hostname}'.")
        self._api_request('POST', f"zones/{self.zone_id}/dns_records", {
            'type': 'A',
            'name': self.hostname,
            'content': ip,
            'ttl': self.ttl
        })

    def _update_record(self, record_id: str, ip: str) -> None:
        self.log_verbose(f"Updating '{ip}' in '{self.hostname}'.")
        self._api_request('PUT', f"zones/{self.zone_id}/dns_records/{record_id}", {
            'type': 'A',
            'name': self.hostname,
            'content': ip,
            'ttl': self.ttl
        })

    def _delete_record(self, record_id: str, ip: str) -> None:
        self.log_verbose(f"Removing '{ip}' from '{self.hostname}'.")
        self._api_request('DELETE', f"zones/{self.zone_id}/dns_records/{record_id}")

    def _api_request(self, method: str, path: str, data: Dict = None) -> Dict:
        url = f"https://api.cloudflare.com/client/v4/{path}"
        headers = {
            'Authorization': f'Bearer {self.api_token}',
            'Content-Type': 'application/json'
        }
        
        req = urllib.request.Request(
            url,
            headers=headers,
            method=method,
            data=json.dumps(data).encode() if data else None
        )
        
        try:
            with urllib.request.urlopen(req) as response:
                result = json.loads(response.read())
                if not result['success']:
                    self._handle_api_error(result)
                return result
        except urllib.error.URLError as e:
            print(f"ERROR: API request failed: {str(e)}", file=sys.stderr)
            sys.exit(1)

    def _handle_api_error(self, response: Dict) -> None:
        error = response['errors'][0]
        print(f"ERROR: {error['message']} (code: {error['code']}).", file=sys.stderr)
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description='Update Cloudflare DNS A records with public IPv4 addresses.')
    parser.add_argument('--apiToken', required=True, help='Cloudflare API token')
    parser.add_argument('--zoneId', required=True, help='Cloudflare Zone ID')
    parser.add_argument('--target', required=True, help='Target hostname')
    parser.add_argument('--source', action='append', default=[], help='Network interface(s)')
    parser.add_argument('--ttl', type=int, default=60, help='TTL for DNS records')
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    args = parser.parse_args()

    ddns = CloudflareDDNS(args.apiToken, args.zoneId, args.target, args.ttl, args.verbose)
    source_ips = ddns.get_public_ipv4_addresses(args.source)
    target_records = ddns.get_dns_records(source_ips)
    ddns.sync_records(source_ips, target_records)

if __name__ == '__main__':
    main()
