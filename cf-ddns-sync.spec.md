# Overview

Create a BASH script named `cf-ddns-sync.sh` to update Cloudflare DNS A records with the IPv4 addresses from specified network interfaces.

Use the Cloudflare REST API (documentation available at https://developers.cloudflare.com/api/) to perform the updates.

Cloudlare API requires an API TOKEN for authentication.



All `curl` commands must store the HTTP response in a variable. The response will always be in JSON format. If the `success` property in the JSON response is `false`, the script should:
  1. Write `ERROR: $error_message (code: $error_code).` to `stderr`, where `$error_code` and `$error_message` correspond to the `code` and `message` properties of the first object in the `errors` array of the JSON response.
  2. Exit immediately with a status code of `1`.

The script should return a status code of `0` upon successful completion without errors.



The script should have a command-line argument parser that accepts the following options:

    cf-ddns-sync.sh --apiToken 145976123897469278364 --zoneId aabbccddeeff --target host1.example.com --source eth0 --source eth1

- `--apiToken`: (Required) Specifies the Cloudflare API Token for API authentication.
- `--zoneId`: (Required) Identifies the DNS Zone ID for the target DNS record, necessary for API calls.
- `--target`: (Required) Provides the hostname for the Cloudflare DNS record, which must already exist in the specified zone.
- `--source`: (Optional) Lists the network interfaces from which to retrieve IPv4 addresses; can accept zero, one, or multiple interfaces.
- `--ttl`: (Optional) Integer value for the `ttl` property of the DNS records.  If unspecified, it should default to `60`.

The script must strictly avoid outputting any content to `stdout`.

When invoked with the `-v` or `--verbose` flags, it may produce specific informative messages (referred to as verbose messages), which should be directed exclusively to `stderr`.

The argument parser should validate all inputs and provide usage instructions if `-h` or `--help` is passed.

Upon validation of all arguments, the script execution should proceed as follows:



# STEP 1:

For each specified network interface in `--source`, the script should retrieve the public IPv4 address following these steps:

1. **Retrieve Local IPv4 Address**: First, obtain the local IPv4 address of each interface (`$SOURCE_INTERFACE_NAME` in the code below):

        ip -4 -oneline address show $SOURCE_INTERFACE_NAME |
            grep --only-matching --perl-regexp '((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}' |
                head -n 1

2. **Query Public IPv4 Address**: Once the local IP is identified, use `dig` command to query the public IPv4 address from a DNS server:

        dig -b $IFACE_LOCAL_IPV4_ADDRESS +short txt ch whoami.cloudflare @1.1.1.1 |
            tr -d '\"'

In verbose mode, the script should display the verbose message `Got IPv4 address '$PUBLIC_IPV4_ADDRESS' for interface '$SOURCE_INTERFACE_NAME'.` immediately after executing the `dig` command. This message must appear for each network interface specified in `--source`, providing clarity on the interface being processed.



However, if no `--source` argument is provided, the script should skip retrieving the local IPv4 address and directly use the `dig` command without specifying the `-b` option:

    dig +short txt ch whoami.cloudflare @1.1.1.1 |
        tr -d '\"'

In verbose mode, the script should display the verbose message `Got IPv4 address '$PUBLIC_IPV4_ADDRESS'.` immediately after executing the `dig` command.



If the `dig` command for a given network interface returns an empty response that network interface must be ignored.

If the `dig` command for a specific network interface returns an IPv4 address that has already been returned by another interface, that IPv4 address should be disregarded and not added to the list again.

If no public IPv4 address could be obtained from any interface, the script should write `ERROR: Cannot get public IPv4 address.` to `stderr` and exit immediately with a status code of `1`.



# STEP 2:

Now, to synchronize the list of DNS A records of the target hostname with the list of public IPv4 addresses obtained in the previous step (lets call it SOURCE_IPV4_ADDRESSES), the script should perform the following steps:

1. **Retrieve Current DNS A Records**: Implement a caching mechanism for DNS records following these rules:

   a. Cache Location: Store the cache in `/var/cache/cf-ddns/${TARGET_HOSTNAME}.cache` as a plaintext file.

   b. Cache Format: The cache file must contain the known IPv4 addresses of the DNS A records for that TARGET_HOSTNAME, with one address per line.

   c. Cache Validation:
      - If the cache file doesn't exists or isn't readable, fetch the records from Cloudflare API.
      - If any address in SOURCE_IPV4_ADDRESSES are not present in local cache, fetch the records from Cloudflare API.
      - If the count of elements in SOURCE_IPV4_ADDRESSES differs from the count of addresses in local cache, fetch the records from Cloudflare API.
      - Otherwise, use the local cached records.

   If no records are returned (from cache or API) the script should write `ERROR: Unknown host '$TARGET_HOSTNAME'.` to `stderr` and exit immediately with a status code of `1`.

2. **Compare and Synchronize DNS A Records**: For each IP in SOURCE_IPV4_ADDRESSES, check if there’s a corresponding DNS A record in TARGET_DNS_RECORDS. There are 4 possible scenarios:
    - Skip: If an existing record already has the correct IP, skip the update to avoid redundant API calls.
    - Insert: If an IP in SOURCE_IPV4_ADDRESSES does not exist in TARGET_DNS_RECORDS, create a new DNS A record for it.
    - Update: If a matching DNS A record exists but with a different IP, update the record with the new IP.
    - Delete: For any IP in TARGET_DNS_RECORDS that is not present in SOURCE_IPV4_ADDRESSES, delete the DNS A record to ensure synchronization.

    In `Insert` or `Update` scenarios, the API call payload must include a `ttl` property, with the value specified through the `--ttl` argument.

    In verbose mode, for each of the four possible scenarios above, the script should display a corresponding verbose message:

    - Skip: `Skipping '$TARGET_DNS_RECORD'.`
    - Insert: `Adding '$SOURCE_IPV4_ADDRESS' to '$TARGET_DNS_RECORD'.`
    - Update: `Updating '$SOURCE_IPV4_ADDRESS' in '$TARGET_DNS_RECORD'.`
    - Delete: `Removing '$SOURCE_IPV4_ADDRESS' from '$TARGET_DNS_RECORD'.`

    Once all synchronization API calls have been executed, it is essential to refresh the local cache file to ensure that its data remains consistent with the changes made through the API.
    
    When writing the cache file, if necessary, create the cache directory.

The final outcome should be that TARGET_DNS_RECORDS reflects the exact set of IPv4 addresses in SOURCE_IPV4_ADDRESSES, ensuring the DNS records are accurate and up-to-date with the public IPs of the specified interfaces.
