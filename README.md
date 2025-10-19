# Cloudflare Dynamic DNS Updater

A Python script for keeping Cloudflare DNS A records synchronized with your current public IPv4 address(es). Features Multi-WAN support and automatic systemd service installation.



## Features

- **Multi-WAN Support**: Detect and manage multiple public IPv4 addresses across different network interfaces
- **Automatic IPv4 Detection**: Query public IP using Cloudflare's DNS infrastructure
- **Smart Caching**: Minimizes API calls by caching DNS records locally
- **Flexible Logging**: Three levels of verbosity (normal, verbose, debug)
- **systemd Integration**: Easy service installation with automatic timer setup
- **Self-contained**: Uses only Python Standard Library - no external dependencies

**Note**: IPv6 support is currently not implemented.



## Prerequisites

- Python 3.6 or higher
- Domain managed by Cloudflare
- Cloudflare API token with DNS edit permissions ([How to create](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/))
- Cloudflare DNS [Zone ID](https://developers.cloudflare.com/fundamentals/setup/find-account-and-zone-ids/)
- Target DNS A record (will be created if it doesn't exist)
- Linux system with `systemd` (for service installation)



## Installation

1. Clone this repository or download the script:
   ```bash
   wget https://raw.githubusercontent.com/fdcastel/cf-ddns/master/cf-ddns.py
   chmod +x cf-ddns.py
   ```

2. For system-wide installation (optional):
   ```bash
   sudo cp cf-ddns.py /usr/local/bin/cf-ddns
   ```



## Usage

The script provides four commands: `sync`, `install`, `uninstall`, and `status`.

### Command: `sync` - Manual DNS Update

Synchronize DNS records once:

```bash
API_TOKEN=YOUR_CLOUDFLARE_API_TOKEN
ZONE_ID=YOUR_CLOUDFLARE_ZONE_ID
TARGET_HOSTNAME=myhost.example.com

./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME
```

This retrieves your public IPv4 address and updates the DNS A record accordingly.

#### Multi-WAN Configuration

For systems with multiple WAN connections, specify network interfaces:

```bash
./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID \
  --target $TARGET_HOSTNAME \
  --source eth0 --source eth1
```

This creates a [round-robin DNS record](https://www.cloudflare.com/learning/dns/glossary/round-robin-dns/) with multiple A records, one for each unique public IP. Interfaces without internet connectivity are automatically ignored.

#### Logging Options

- **Normal** (default): Only errors are shown
  ```bash
  ./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME
  ```

- **Verbose** (`--verbose`): Shows actual changes (additions, updates, deletions)
  ```bash
  ./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME --verbose
  ```

- **Debug** (`--debug`): Shows everything including diagnostic information
  ```bash
  ./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME --debug
  ```

#### Additional Options

- `--ttl`: Set DNS record TTL in seconds (default: 60)
  ```bash
  ./cf-ddns.py sync --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME --ttl 300
  ```



### Command: `install` - Systemd Service

Install as a systemd service to keep DNS records automatically updated:

```bash
sudo ./cf-ddns.py install --apiToken $API_TOKEN --zoneId $ZONE_ID --target $TARGET_HOSTNAME
```

This creates:
- A systemd service that runs the sync command
- A systemd timer that triggers every minute
- Automatic cache management to minimize API calls

The service runs with `--verbose` logging by default, so you'll see log entries only when DNS records are actually changed.

#### Multiple Services

You can install multiple services for different hostnames:

```bash
sudo ./cf-ddns.py install --apiToken $API_TOKEN --zoneId $ZONE_ID --target host1.example.com
sudo ./cf-ddns.py install --apiToken $API_TOKEN --zoneId $ZONE_ID --target host2.example.com --source eth1
```



### Command: `status` - Check Service

View the status and recent logs of an installed service:

```bash
sudo ./cf-ddns.py status --target $TARGET_HOSTNAME
```

This displays:
- Timer status and schedule
- Service status
- Last 20 log entries



### Command: `uninstall` - Remove Service

Uninstall a systemd service:

```bash
sudo ./cf-ddns.py uninstall --target $TARGET_HOSTNAME
```

This removes the service, timer, and disables automatic updates.



## How It Works

1. **IP Detection**: Queries Cloudflare's DNS server (1.0.0.1) to determine public IPv4 address(es)
2. **Cache Check**: Reads local cache to avoid unnecessary API calls
3. **Synchronization**: Compares current IPs with DNS records and:
   - **Adds** new IP addresses as A records
   - **Updates** existing records if TTL changed
   - **Removes** old IP addresses no longer active
   - **Skips** records already synchronized
4. **Cache Update**: Refreshes local cache after changes



## Cache Management

The script maintains a cache in `/var/cache/cf-ddns/` to minimize Cloudflare API calls:

- Cache files are named `{hostname}.cache`
- Contains timestamp and current DNS records
- Automatically validated on each run
- Refreshed after successful synchronization

This design ensures the service can run every minute with minimal API impact.



## Log Behavior

The logging system is designed to minimize noise:

- **Normal mode**: Silent operation - logs only appear when there are errors
- **Verbose mode** (used by systemd service): Logs only when DNS records change (add/update/delete)
- **Debug mode**: Logs all operations including when records are already correct

This means an installed service will produce **zero log entries per minute** during normal operation when IPs haven't changed.



## Examples

### Single WAN Setup
```bash
# Manual sync
./cf-ddns.py sync --apiToken $TOKEN --zoneId $ZONE --target home.example.com --verbose

# Install service
sudo ./cf-ddns.py install --apiToken $TOKEN --zoneId $ZONE --target home.example.com
```

### Multi-WAN Setup (Load Balancing)
```bash
# Two WAN connections on eth0 and eth1
./cf-ddns.py sync --apiToken $TOKEN --zoneId $ZONE \
  --target office.example.com \
  --source eth0 --source eth1 \
  --verbose

# Install service
sudo ./cf-ddns.py install --apiToken $TOKEN --zoneId $ZONE \
  --target office.example.com \
  --source eth0 --source eth1
```

### Custom TTL
```bash
# 5-minute TTL
./cf-ddns.py sync --apiToken $TOKEN --zoneId $ZONE \
  --target server.example.com \
  --ttl 300
```



## Troubleshooting

### Check service status
```bash
sudo ./cf-ddns.py status --target $TARGET_HOSTNAME
```

### View systemd logs
```bash
# Last 50 entries
sudo journalctl -u cf-ddns-$TARGET_HOSTNAME.service -n 50

# Follow logs in real-time
sudo journalctl -u cf-ddns-$TARGET_HOSTNAME.service -f
```

### Manual sync with debug output
```bash
./cf-ddns.py sync --apiToken $TOKEN --zoneId $ZONE --target $HOSTNAME --debug
```

### Check cache
```bash
cat /var/cache/cf-ddns/$TARGET_HOSTNAME.cache
```



## Security Notes

- Store API tokens securely - consider using environment variables or secret management
- The API token only needs `Zone.DNS` edit permission for the specific zone
- Service files are stored in `/etc/systemd/system/` and run as root
- Cache files in `/var/cache/cf-ddns/` are world-readable by default



## Notes on Code Generation

This project is part of a research initiative examining AI-assisted code generation.

The Python script (`cf-ddns.py`) was **entirely generated** by GitHub Copilot (powered by Claude Sonnet 4.5) based on human-written specifications in the `cf-ddns.spec.md` file.

All implementation details, error handling, and edge cases were handled by the AI. The only human-authored files are the specification documents (`.spec.md`) and documentation (`.md` files).

The commit history shows the project's evolution and demonstrates the AI's capability to implement complex, production-ready tools from detailed specifications.

While AI-generated, the design, requirements, and testing were performed under human supervision to ensure quality and security. 
