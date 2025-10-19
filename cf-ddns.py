#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Dict, Optional, Tuple


class Logger:
    """Handles logging with debug, verbose, and normal modes."""
    
    def __init__(self, debug: bool = False, verbose: bool = False):
        self.debug = debug
        self.verbose = verbose or debug  # debug implies verbose
    
    def log_debug(self, message: str):
        """Log debug messages (only in debug mode)."""
        if self.debug:
            print(message, file=sys.stderr)
    
    def log_verbose(self, message: str):
        """Log verbose messages (in verbose or debug mode)."""
        if self.verbose:
            print(message, file=sys.stderr)
    
    def log_error(self, message: str):
        """Log error messages (always shown)."""
        print(message, file=sys.stderr)


def run_command(command: List[str]) -> Tuple[int, str]:
    """Execute a shell command and return exit code and output."""
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, ""
    except Exception:
        return 1, ""


def get_ipv4_from_interface(interface: str, logger: Logger) -> Optional[str]:
    """Get public IPv4 address for a specific network interface."""
    # Get local IPv4 address
    returncode, output = run_command(['ip', '-4', '-oneline', 'address', 'show', interface])
    if returncode != 0:
        return None
    
    # Extract IPv4 address using regex
    match = re.search(r'((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}', output)
    if not match:
        return None
    
    local_ip = match.group(0)
    
    # Query public IPv4 from DNS
    returncode, output = run_command([
        'dig', '-b', local_ip, '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.0.0.1'
    ])
    
    if returncode != 0 or not output:
        return None
    
    # Remove quotes
    public_ip = output.strip('"')
    
    logger.log_debug(f"Got IPv4 address '{public_ip}' for interface '{interface}'.")
    
    return public_ip


def get_public_ipv4(logger: Logger) -> Optional[str]:
    """Get public IPv4 address without specifying an interface."""
    returncode, output = run_command([
        'dig', '+short', 'txt', 'ch', 'whoami.cloudflare', '@1.0.0.1'
    ])
    
    if returncode != 0 or not output:
        return None
    
    # Remove quotes
    public_ip = output.strip('"')
    
    logger.log_debug(f"Got IPv4 address '{public_ip}'.")
    
    return public_ip


def get_source_ipv4_addresses(sources: List[str], logger: Logger) -> List[str]:
    """Determine the list of public IPv4 addresses from sources."""
    addresses = []
    seen = set()
    
    if not sources:
        # No source specified, get public IP directly
        ip = get_public_ipv4(logger)
        if ip:
            addresses.append(ip)
    else:
        # Get IP for each specified interface
        for interface in sources:
            ip = get_ipv4_from_interface(interface, logger)
            if ip and ip not in seen:
                addresses.append(ip)
                seen.add(ip)
    
    if not addresses:
        logger.log_error("ERROR: Cannot get public IPv4 address.")
        sys.exit(1)
    
    # Sort and return
    return sorted(addresses)


def get_cache_path(target_hostname: str) -> Path:
    """Get the cache file path for a target hostname."""
    cache_dir = Path('/var/cache/cf-ddns')
    return cache_dir / f"{target_hostname}.cache"


def read_cache(target_hostname: str) -> Optional[List[Dict]]:
    """Read DNS A records from cache if valid."""
    cache_path = get_cache_path(target_hostname)
    
    try:
        with open(cache_path, 'r') as f:
            cache_data = json.load(f)
            records = cache_data.get('records', [])
            # Sort by IP address
            return sorted(records, key=lambda r: r.get('content', ''))
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return None


def write_cache(target_hostname: str, records: List[Dict]):
    """Write DNS A records to cache."""
    cache_path = get_cache_path(target_hostname)
    
    # Create cache directory if needed
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    
    cache_data = {
        'timestamp': int(time.time()),
        'records': sorted(records, key=lambda r: r.get('content', ''))
    }
    
    try:
        with open(cache_path, 'w') as f:
            json.dump(cache_data, f, indent=2)
    except Exception:
        pass  # Ignore cache write errors


def cloudflare_api_call(method: str, endpoint: str, api_token: str, data: Optional[Dict] = None) -> Dict:
    """Make a call to the Cloudflare API."""
    import urllib.request
    import urllib.error
    
    url = f"https://api.cloudflare.com/client/v4{endpoint}"
    
    headers = {
        'Authorization': f'Bearer {api_token}',
        'Content-Type': 'application/json'
    }
    
    request_data = json.dumps(data).encode('utf-8') if data else None
    
    req = urllib.request.Request(url, data=request_data, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode('utf-8'))
    except Exception:
        return {'success': False, 'errors': [{'code': 0, 'message': 'Network error'}]}


def get_dns_records_from_api(api_token: str, zone_id: str, target_hostname: str) -> List[Dict]:
    """Fetch DNS A records for target hostname from Cloudflare API."""
    endpoint = f"/zones/{zone_id}/dns_records?type=A&name={target_hostname}"
    response = cloudflare_api_call('GET', endpoint, api_token)
    
    if not response.get('success', False):
        errors = response.get('errors', [{}])
        error = errors[0] if errors else {}
        error_code = error.get('code', 'unknown')
        error_message = error.get('message', 'Unknown error')
        print(f"ERROR: {error_message} (code: {error_code}).", file=sys.stderr)
        sys.exit(1)
    
    records = response.get('result', [])
    # Sort by IP address
    return sorted(records, key=lambda r: r.get('content', ''))


def get_target_dns_records(api_token: str, zone_id: str, target_hostname: str, 
                           source_addresses: List[str], logger: Logger) -> List[Dict]:
    """Determine DNS A records for target hostname using cache when possible."""
    cached_records = read_cache(target_hostname)
    
    use_cache = False
    if cached_records is not None:
        cached_ips = sorted([r.get('content') for r in cached_records])
        
        # Check if cache is valid
        if len(source_addresses) == len(cached_ips):
            if all(ip in cached_ips for ip in source_addresses):
                use_cache = True
    
    if use_cache:
        records = cached_records
        logger.log_debug(f"DNS A records for '{target_hostname}' = {[r.get('content') for r in records]} (Cached)")
    else:
        records = get_dns_records_from_api(api_token, zone_id, target_hostname)
        logger.log_debug(f"DNS A records for '{target_hostname}' = {[r.get('content') for r in records]}")
    
    return records


def sync_dns_records(api_token: str, zone_id: str, target_hostname: str, 
                     source_addresses: List[str], target_records: List[Dict], 
                     ttl: int, logger: Logger):
    """Synchronize DNS A records with source IPv4 addresses."""
    target_ips = {r.get('content'): r for r in target_records}
    source_ips = set(source_addresses)
    
    updated_records = []
    
    # Process source IPs
    for ip in source_addresses:
        if ip in target_ips:
            record = target_ips[ip]
            # Check if update needed
            if record.get('ttl') != ttl:
                # Update
                logger.log_verbose(f"Updating '{ip}' in '{target_hostname}'.")
                
                endpoint = f"/zones/{zone_id}/dns_records/{record['id']}"
                data = {
                    'type': 'A',
                    'name': target_hostname,
                    'content': ip,
                    'ttl': ttl
                }
                response = cloudflare_api_call('PUT', endpoint, api_token, data)
                
                if not response.get('success', False):
                    errors = response.get('errors', [{}])
                    error = errors[0] if errors else {}
                    error_code = error.get('code', 'unknown')
                    error_message = error.get('message', 'Unknown error')
                    logger.log_error(f"ERROR: {error_message} (code: {error_code}).")
                    sys.exit(1)
                
                updated_records.append(response.get('result', record))
            else:
                # Skip
                logger.log_debug(f"Skipping '{target_hostname}'.")
                updated_records.append(record)
        else:
            # Insert
            logger.log_verbose(f"Adding '{ip}' to '{target_hostname}'.")
            
            endpoint = f"/zones/{zone_id}/dns_records"
            data = {
                'type': 'A',
                'name': target_hostname,
                'content': ip,
                'ttl': ttl
            }
            response = cloudflare_api_call('POST', endpoint, api_token, data)
            
            if not response.get('success', False):
                errors = response.get('errors', [{}])
                error = errors[0] if errors else {}
                error_code = error.get('code', 'unknown')
                error_message = error.get('message', 'Unknown error')
                logger.log_error(f"ERROR: {error_message} (code: {error_code}).")
                sys.exit(1)
            
            updated_records.append(response.get('result'))
    
    # Delete records not in source
    for ip, record in target_ips.items():
        if ip not in source_ips:
            logger.log_verbose(f"Removing '{ip}' from '{target_hostname}'.")
            
            endpoint = f"/zones/{zone_id}/dns_records/{record['id']}"
            response = cloudflare_api_call('DELETE', endpoint, api_token)
            
            if not response.get('success', False):
                errors = response.get('errors', [{}])
                error = errors[0] if errors else {}
                error_code = error.get('code', 'unknown')
                error_message = error.get('message', 'Unknown error')
                logger.log_error(f"ERROR: {error_message} (code: {error_code}).")
                sys.exit(1)
    
    # Update cache
    write_cache(target_hostname, updated_records)


def command_sync(args):
    """Execute the sync command."""
    logger = Logger(debug=args.debug, verbose=args.verbose)
    
    # Step 1: Get source IPv4 addresses
    source_addresses = get_source_ipv4_addresses(args.source, logger)
    
    # Step 2: Get target DNS records
    target_records = get_target_dns_records(
        args.apiToken, args.zoneId, args.target, source_addresses, logger
    )
    
    # Step 3: Synchronize
    sync_dns_records(
        args.apiToken, args.zoneId, args.target, 
        source_addresses, target_records, args.ttl, logger
    )


def command_install(args):
    """Execute the install command."""
    target_name = args.target
    script_path = os.path.abspath(__file__)
    
    # Build command line
    cmd_args = [
        script_path, 'sync',
        '--apiToken', args.apiToken,
        '--zoneId', args.zoneId,
        '--target', args.target,
        '--ttl', str(args.ttl),
        '--verbose'
    ]
    
    for source in args.source:
        cmd_args.extend(['--source', source])
    
    # Create service file
    service_content = f"""[Unit]
Description=Synchronizes DNS records for {target_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart={' '.join(cmd_args)}
TimeoutSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""
    
    service_path = f"/etc/systemd/system/cf-ddns-{target_name}.service"
    
    try:
        with open(service_path, 'w') as f:
            f.write(service_content)
    except Exception as e:
        print(f"ERROR: Failed to create service file: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Create timer file
    timer_content = f"""[Unit]
Description=Keeps DNS records for {target_name} synchronized every minute
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target
"""
    
    timer_path = f"/etc/systemd/system/cf-ddns-{target_name}.timer"
    
    try:
        with open(timer_path, 'w') as f:
            f.write(timer_content)
    except Exception as e:
        print(f"ERROR: Failed to create timer file: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Reload systemd
    subprocess.run(['systemctl', 'daemon-reload'], check=False)
    
    # Stop existing timer
    subprocess.run(['systemctl', 'stop', f'cf-ddns-{target_name}.timer'], check=False)
    
    # Enable and start timer
    result = subprocess.run(
        ['systemctl', 'enable', '--now', f'cf-ddns-{target_name}.timer'],
        capture_output=True
    )
    
    if result.returncode != 0:
        print(f"ERROR: Failed to enable timer.", file=sys.stderr)
        sys.exit(1)


def command_uninstall(args):
    """Execute the uninstall command."""
    target_name = args.target
    
    # Disable and stop timer
    subprocess.run(['systemctl', 'disable', '--now', f'cf-ddns-{target_name}.timer'], check=False)
    
    # Stop service
    subprocess.run(['systemctl', 'stop', f'cf-ddns-{target_name}.service'], check=False)
    
    # Remove timer file
    timer_path = f"/etc/systemd/system/cf-ddns-{target_name}.timer"
    try:
        os.remove(timer_path)
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"ERROR: Failed to remove timer file: {e}", file=sys.stderr)
    
    # Remove service file
    service_path = f"/etc/systemd/system/cf-ddns-{target_name}.service"
    try:
        os.remove(service_path)
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"ERROR: Failed to remove service file: {e}", file=sys.stderr)
    
    # Reload systemd
    subprocess.run(['systemctl', 'daemon-reload'], check=False)


def command_status(args):
    """Execute the status command."""
    target_name = args.target
    service_path = f"/etc/systemd/system/cf-ddns-{target_name}.service"
    
    # Check if service exists
    if not os.path.exists(service_path):
        print(f"ERROR: Service for target '{target_name}' is not installed.", file=sys.stderr)
        sys.exit(1)
    
    # Display timer status
    subprocess.run(['systemctl', 'status', f'cf-ddns-{target_name}.timer'])
    
    print()  # Empty line
    
    # Display service status
    subprocess.run(['systemctl', 'status', f'cf-ddns-{target_name}.service'])
    
    print()  # Empty line
    
    # Display journal entries
    subprocess.run([
        'journalctl', '-u', f'cf-ddns-{target_name}.service',
        '-n', '20', '--no-pager'
    ])


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Manage Cloudflare DNS A records synchronization',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command to execute')
    subparsers.required = True
    
    # sync command
    sync_parser = subparsers.add_parser('sync', help='Synchronize DNS records')
    sync_parser.add_argument('--apiToken', required=True, help='Cloudflare API Token')
    sync_parser.add_argument('--zoneId', required=True, help='DNS Zone ID')
    sync_parser.add_argument('--target', required=True, help='Target hostname')
    sync_parser.add_argument('--source', action='append', default=[], help='Network interface(s)')
    sync_parser.add_argument('--ttl', type=int, default=60, help='TTL value (default: 60)')
    sync_parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
    sync_parser.add_argument('--debug', action='store_true', help='Enable debug output')
    sync_parser.set_defaults(func=command_sync)
    
    # install command
    install_parser = subparsers.add_parser('install', help='Install as systemd service')
    install_parser.add_argument('--apiToken', required=True, help='Cloudflare API Token')
    install_parser.add_argument('--zoneId', required=True, help='DNS Zone ID')
    install_parser.add_argument('--target', required=True, help='Target hostname')
    install_parser.add_argument('--source', action='append', default=[], help='Network interface(s)')
    install_parser.add_argument('--ttl', type=int, default=60, help='TTL value (default: 60)')
    install_parser.set_defaults(func=command_install)
    
    # uninstall command
    uninstall_parser = subparsers.add_parser('uninstall', help='Uninstall systemd service')
    uninstall_parser.add_argument('--target', required=True, help='Target hostname')
    uninstall_parser.set_defaults(func=command_uninstall)
    
    # status command
    status_parser = subparsers.add_parser('status', help='Show service status')
    status_parser.add_argument('--target', required=True, help='Target hostname')
    status_parser.set_defaults(func=command_status)
    
    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
