# Overview

Create a PYTHON 3 script named `cf-ddns` to manage Cloudflare DNS A records synchronization with the IPv4 addresses from specified network interfaces.

The script must start with a shebang for python 3 language.

The script must use only libraries from The Python Standard Library. For http requests, use `urllib` and `json`.

Use the Cloudflare REST API (documentation available at https://developers.cloudflare.com/api/) to perform the updates.

Cloudflare API requires an API TOKEN for authentication.

The script must strictly avoid outputting any content to `stdout` (except for the `status` command, which is purely diagnostic).

The script supports three levels of logging to `stderr`:
- **Normal mode** (no flags): Only errors are output to `stderr`
- **Verbose mode** (`-v` or `--verbose`): Errors plus actual changes (Insert, Update, Delete operations) are output to `stderr`
- **Debug mode** (`--debug`): Everything is output to `stderr` (all messages including Skip operations)

# Hostname validation

Wherever the spec accepts a `--target HOSTNAME` argument, the value must match the regular expression `^[A-Za-z0-9._-]+$`. If it does not, the script must write `ERROR: Invalid target hostname '$TARGET_HOSTNAME'.` to `stderr` and exit immediately with status code `1`. This rule prevents path traversal when the hostname is interpolated into filesystem paths.

# Test/CI override: CF_DDNS_ETC_DIR

If the environment variable `CF_DDNS_ETC_DIR` is set, the `install`, `uninstall`, and `status` commands must:
- Use `$CF_DDNS_ETC_DIR/systemd/system/` as the systemd unit directory instead of `/etc/systemd/system/`.
- Use `$CF_DDNS_ETC_DIR/cf-ddns/` as the secrets directory instead of `/etc/cf-ddns/`.
- Skip every `systemctl ...`, `journalctl ...`, and `daemon-reload` invocation (the directories may not be a real systemd root).
- For `status`, print only the unit file paths and the contents of the `.env` file (token redacted as `***`).

This override exists exclusively so the install/uninstall/status flows can be exercised in CI without root privileges or a real systemd. The override is invisible to normal users.



# Command-Line Interface

The script should have a command-line argument parser that accepts a COMMAND as the first positional argument, followed by command-specific options.

The general usage pattern is:

    cf-ddns <command> [options]

Available commands:
- `sync`: Synchronizes DNS records for a target hostname
- `install`: Installs the script as a systemd service
- `uninstall`: Uninstalls the systemd service
- `status`: Displays the result of the last execution

The argument parser should validate all inputs and provide usage instructions if `-h` or `--help` is passed.



# COMMAND: sync

Synchronizes Cloudflare DNS A records with IPv4 addresses from specified network interfaces.

## Usage

    cf-ddns sync --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [--ttl TTL] [-v|--verbose] [--debug]

## Arguments

- `--apiToken`: (Required) Specifies the Cloudflare API Token for API authentication.
- `--zoneId`: (Required) Identifies the DNS Zone ID for the target DNS record, necessary for API calls.
- `--target`: (Required) Provides the hostname for the Cloudflare DNS record, which must already exist in the specified zone. Let's call it TARGET_HOSTNAME.
- `--source`: (Optional) Lists the network interfaces from which to retrieve IPv4 addresses; can accept zero, one, or multiple interfaces.
- `--ttl`: (Optional) Integer value for the `ttl` property of the DNS records. If unspecified, it should default to `60`.
- `-v`, `--verbose`: (Optional) Enable verbose output to stderr. Shows errors and actual changes (Insert, Update, Delete operations).
- `--debug`: (Optional) Enable debug output to stderr. Shows everything including all operations (Skip, Insert, Update, Delete). Takes precedence over `--verbose`.

## Execution Steps

Upon validation of all arguments, the script execution should proceed as follows:

### STEP 1: Determine the list of public IPv4 addresses.

For each specified network interface in `--source`, the script should retrieve the public IPv4 address associated with that interface following these steps:

1. **Retrieve Local IPv4 Address**: First, obtain the local IPv4 address of each interface (`$SOURCE_INTERFACE_NAME` in the code below) using the `ip` command:

        ip -4 -oneline address show $SOURCE_INTERFACE_NAME

    The result is the first match in the command output against the regex `\b(?:\d{1,3}\.){3}\d{1,3}\b`. The match must additionally be validated by passing it through `ipaddress.IPv4Address(...)`; on `ValueError`, the interface is treated as having no usable IP and is skipped.

2. **Query Public IPv4 Address**: Once the local IP is identified, use `dig` command to query the public IPv4 address from a DNS server:

        dig -b $IFACE_LOCAL_IPV4_ADDRESS +short +time=3 +tries=1 txt ch whoami.cloudflare @1.0.0.1

    The output of the above command will include double quotes around the result, which should be removed. The `+time=3 +tries=1` flags cap each `dig` invocation at ~3 seconds so that, with multiple interfaces, the cumulative time stays well within the systemd `TimeoutSec=30` budget.

In debug mode, the script should display the message `Got IPv4 address '$PUBLIC_IPV4_ADDRESS' for interface '$SOURCE_INTERFACE_NAME'.` immediately after executing the `dig` command. This message must appear for each network interface specified in `--source`, providing clarity on the interface being processed.

However, if no `--source` argument is provided, the script should skip retrieving the local IPv4 address and directly use the `dig` command without specifying the `-b` option:

    dig +short +time=3 +tries=1 txt ch whoami.cloudflare @1.0.0.1

The output of the above command will include double quotes around the result, which should be removed.

In debug mode, the script should display the message `Got IPv4 address '$PUBLIC_IPV4_ADDRESS'.` immediately after executing the `dig` command.

If the `dig` command for a given network interface returns an empty response that network interface must be ignored.

If the `dig` command for a specific network interface returns an IPv4 address that has already been returned by another interface, that IPv4 address should be disregarded and not added to the list again.

If no public IPv4 address could be obtained from any interface, the script should write `ERROR: Cannot get public IPv4 address.` to `stderr` and exit immediately with a status code of `1`.

The expected result of this step is a list of public IPv4 addresses called SOURCE_IPV4_ADDRESSES. This list must be sorted.

### STEP 2: Determine the DNS A Records for target hostname.

The DNS A Records for TARGET_HOSTNAME can be queried using the Cloudflare API.

However, to avoid many unnecessary calls to the API, a cache mechanism should be implemented following these rules:

   - Cache Location: Store the cache in `/var/cache/cf-ddns/${TARGET_HOSTNAME}.cache` as a JSON file.

   - Cache Format: The cache file must contain
      - `timestamp`: Unix timestamp of when the cache was last updated.
      - `records`: Array of DNS A records from the last Cloudflare API response. This array must be sorted by the ip address of each element.

   - Cache Concurrency: Before reading or writing the cache file, the script must acquire an exclusive advisory lock on the cache file (using `fcntl.flock(..., LOCK_EX)`). The lock is held for the entire sync execution and is released automatically when the process exits. If acquiring the lock fails (e.g., another sync is already running), exit immediately with status `0` (silently — this is the expected case when the systemd timer fires while a previous run is still in progress).

   - Cache Validation:
      - If the cache file doesn't exists or isn't readable, fetch the records from Cloudflare API.
      - If any of ipv4 address in SOURCE_IPV4_ADDRESSES are not present in local cache, fetch the records from Cloudflare API.
      - If the count of elements in SOURCE_IPV4_ADDRESSES differs from the count of elements in local cache, fetch the records from Cloudflare API.
      - Otherwise, use the local cached records.

   In debug mode, the script should display the message: `DNS A records for '$TARGET_HOSTNAME' = [$IP1, $IP2, ...]` where the bracketed list contains the IP addresses (sorted ascending, comma-space separated, no quotes around individual IPs, e.g. `[1.2.3.4, 5.6.7.8]`; an empty list is `[]`). If obtained from cache the message must also append the suffix ` (Cached)`.
   
   If no records are returned (from cache or API) this step must return an empty list.

   The expected result of this step is a list of DNS A Records called TARGET_DNS_RECORDS. This list must be sorted by the ip address of each record.

### STEP 3: Compare and Synchronize DNS A Records for target hostname.

Now, to synchronize the list TARGET_DNS_RECORDS with the list SOURCE_IPV4_ADDRESSES, perform the following steps. In all messages below, `$TARGET_DNS_RECORD` refers to the IP address of the existing DNS A record (the `content` field of the Cloudflare record) — *not* the hostname.

The script matches records by IP address only. There are four possible scenarios:

  - **Skip**: An IP in SOURCE_IPV4_ADDRESSES is already present in TARGET_DNS_RECORDS *with the matching `--ttl` value*. No API call is made.
  - **Update**: An IP in SOURCE_IPV4_ADDRESSES is already present in TARGET_DNS_RECORDS *but the existing record's `ttl` differs from the `--ttl` value*. A `PUT` is made to refresh the TTL.
  - **Insert**: An IP in SOURCE_IPV4_ADDRESSES does not exist in TARGET_DNS_RECORDS. A `POST` is made to create the record.
  - **Delete**: An IP in TARGET_DNS_RECORDS is not present in SOURCE_IPV4_ADDRESSES. A `DELETE` is made to remove the record.

Note that an IP *change* (e.g., the public IP rotates from `1.2.3.4` to `5.6.7.8`) is *not* an Update — the old IP triggers a Delete and the new IP triggers an Insert. There is no stable identifier to pair a "changed" record with a "source" IP, so the spec deliberately treats them as independent operations.

In `Insert` and `Update` scenarios, the API call payload must include the `type` (`A`), `name` (`$TARGET_HOSTNAME`), `content` (the IPv4 address), and `ttl` (from `--ttl`) properties.

For each of the four possible scenarios above, the script should display messages according to the logging mode:
  - **Debug mode** (shows all operations):
    - Skip: `Skipping '$TARGET_DNS_RECORD'.`
    - Insert: `Adding '$SOURCE_IPV4_ADDRESS' to '$TARGET_HOSTNAME'.`
    - Update: `Updating '$SOURCE_IPV4_ADDRESS' in '$TARGET_HOSTNAME'.`
    - Delete: `Removing '$TARGET_DNS_RECORD' from '$TARGET_HOSTNAME'.`
  - **Verbose mode** (shows only actual changes):
    - Skip: _(no message)_
    - Insert: `Adding '$SOURCE_IPV4_ADDRESS' to '$TARGET_HOSTNAME'.`
    - Update: `Updating '$SOURCE_IPV4_ADDRESS' in '$TARGET_HOSTNAME'.`
    - Delete: `Removing '$TARGET_DNS_RECORD' from '$TARGET_HOSTNAME'.`
  - **Normal mode** (no flag):
    - _(no messages for any operation, only errors)_

Once all synchronization API calls have been executed, it is essential to refresh the local cache file to ensure that its data remains consistent with the changes made through the API.

When writing the cache file:
- If necessary, create the cache directory.
- Write atomically: serialize JSON to `${cache_path}.tmp` then `os.replace()` it over the final path. This prevents a corrupt cache if the process is killed mid-write.
- If the cache write fails (e.g., disk full, permission denied), emit `WARNING: Failed to update cache: $error_message` to `stderr` but do *not* exit non-zero — the API operations have already succeeded and the next run will rebuild the cache.

For all API calls of this step the HTTP response will always be in JSON format. If the `success` property in the JSON response is `false`, the script should:

  1. Write `ERROR: $error_message (code: $error_code).` to `stderr`, where `$error_code` and `$error_message` correspond to the `code` and `message` properties of the first object in the `errors` array of the JSON response.

  2. Exit immediately with a status code of `1`

For network-level failures (timeout, connection refused, TLS error, DNS failure, etc.), the script must write `ERROR: Network error: $exception_class: $exception_message.` to `stderr` and exit immediately with status code `1`. This replaces the prior generic "Network error" so that operators can diagnose problems from the journal without enabling debug mode.

The final outcome should be that TARGET_DNS_RECORDS reflects the exact set of IPv4 addresses in SOURCE_IPV4_ADDRESSES, ensuring the DNS records are accurate and up-to-date with the public IPs of the specified interfaces.



# COMMAND: install

Installs the `cf-ddns` script as a systemd service on Linux.

## Usage

    cf-ddns install --apiToken TOKEN --zoneId ZONE_ID --target HOSTNAME [--source INTERFACE]... [--ttl TTL]

## Arguments

This command accepts the same arguments as the `sync` command, except the `--verbose` argument.

- `--apiToken`: (Required) Specifies the Cloudflare API Token for API authentication.
- `--zoneId`: (Required) Identifies the DNS Zone ID for the target DNS record.
- `--target`: (Required) Provides the hostname for the Cloudflare DNS record. Let's call its value TARGET_NAME.
- `--source`: (Optional) Lists the network interfaces from which to retrieve IPv4 addresses; can accept zero, one, or multiple interfaces.
- `--ttl`: (Optional) Integer value for the `ttl` property of the DNS records. If unspecified, it should default to `60`.

## Execution Steps

Upon validation of all arguments, the script execution should proceed as follows:

The script must first write the API token to a secrets file:
  - Path: `/etc/cf-ddns/$TARGET_NAME.env` (subject to the `CF_DDNS_ETC_DIR` override).
  - Permissions: `0600`, owned by root.
  - Content: a single line `CF_API_TOKEN=$TOKEN` (no quoting; systemd `EnvironmentFile` parses bare values).
  - The directory must be created with permissions `0700` if it does not exist.

The script must create a `systemd` SERVICE with the following requirements:
  - The service is required to execute the `cf-ddns sync` command, passing along all arguments received from the command line plus the `--verbose` argument, *except* `--apiToken` which is read from the environment via `EnvironmentFile`. Pass the token as `--apiToken ${CF_API_TOKEN}` so that systemd substitutes it from the environment at exec time. This keeps the API token out of `/etc/systemd/system/`, which is world-readable by default.
  - The service must reference the secrets file via `EnvironmentFile=/etc/cf-ddns/$TARGET_NAME.env` (subject to `CF_DDNS_ETC_DIR`).
  - The service must execute the script from its current absolute path. Use `os.path.realpath(__file__)` (resolving symlinks), so that uninstalling the symlink target later does not break the service.
  - The service description should be in the format: `Synchronizes DNS records for $TARGET_NAME`, where $TARGET_NAME is the value from the `--target` argument.
  - The service file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.service`.
  - The service type should be set to `oneshot`.
  - The service execution must be terminated if it runs longer than 30 seconds.
  - The service output should be logged in `systemd` journal.
  - The service should be configured to execute only after the network is available.

The script must also create a `systemd` TIMER with the following specifications:
  - The timer description should be in the format: `Keeps DNS records for $TARGET_NAME synchronized every minute`.
  - The timer file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.timer`.
  - The timer should be configured to execute only after the network is available.
  - The timer should trigger the service every minute.
  - The timer must set `AccuracySec=1min` so that systemd can batch wakeups with other timers and conserve power. (The default of 1 minute happens to match this, but pinning it here makes the unit file deterministic for testing.)

The script should then execute the following steps:
  1. Reload the `systemd` manager configuration using `systemctl daemon-reload`.
  2. Stop any pre-existing timer instance with `systemctl stop cf-ddns-$TARGET_NAME.timer`.
  3. Enable and start the timer using `systemctl enable --now cf-ddns-$TARGET_NAME.timer`.

Both systemd units (the service and timer) must be created in the `/etc/systemd/system/` directory (subject to the `CF_DDNS_ETC_DIR` override).

When `CF_DDNS_ETC_DIR` is set, all `systemctl` invocations above are skipped (the override directory is not a real systemd root).



# COMMAND: uninstall

Uninstalls the systemd service created by the `install` command.

## Usage

    cf-ddns uninstall --target HOSTNAME

## Arguments

- `--target`: (Required) The hostname that identifies which systemd service to uninstall. Let's call its value TARGET_NAME.

## Execution Steps

This command should revert everything done by the `install` command, in the reverse order:

1. Stop and disable the timer using `systemctl disable --now cf-ddns-$TARGET_NAME.timer`.
2. Stop the service (if running) using `systemctl stop cf-ddns-$TARGET_NAME.service`.
3. Remove the timer unit file `/etc/systemd/system/cf-ddns-$TARGET_NAME.timer`.
4. Remove the service unit file `/etc/systemd/system/cf-ddns-$TARGET_NAME.service`.
5. Remove the secrets file `/etc/cf-ddns/$TARGET_NAME.env`.
6. Reload the `systemd` manager configuration using `systemctl daemon-reload`.

All paths above are subject to the `CF_DDNS_ETC_DIR` override. Missing files at any step are not an error (the file may have been removed manually). When `CF_DDNS_ETC_DIR` is set, all `systemctl` invocations are skipped.



# COMMAND: status

Displays the result of the last execution of a given target.

## Usage

    cf-ddns status --target HOSTNAME

## Arguments

- `--target`: (Required) The hostname that identifies which systemd service to check. Let's call its value TARGET_NAME.

## Execution Steps

This command should display information about the systemd service and timer for the specified target:

1. Check if the service unit file `/etc/systemd/system/cf-ddns-$TARGET_NAME.service` exists (subject to `CF_DDNS_ETC_DIR`). If not, write `ERROR: Service for target '$TARGET_NAME' is not installed.` to `stderr` and exit with status code `1`.

2. Display the status of the timer using `systemctl status cf-ddns-$TARGET_NAME.timer`.

3. Display the status of the service using `systemctl status cf-ddns-$TARGET_NAME.service`.

4. Display the last 20 journal entries for the service using `journalctl -u cf-ddns-$TARGET_NAME.service -n 20 --no-pager`.

All output from the above commands should be displayed to `stdout`.

When `CF_DDNS_ETC_DIR` is set, steps 2-4 are replaced with: print the absolute path of the service unit file, the absolute path of the timer unit file, and the contents of the secrets `.env` file with the value of `CF_API_TOKEN` redacted as `***`. This makes the install/uninstall flow inspectable in CI without a real systemd.
