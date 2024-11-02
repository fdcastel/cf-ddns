Create a BASH script named `cf-ddns-sync.sh` to update Cloudflare DNS A records with the IPv4 addresses from specified network interfaces.

Use the Cloudflare REST API (documentation available at https://developers.cloudflare.com/api/) to perform the updates. 

Cloudlare API requires an API TOKEN for authentication.



The script should have a command-line argument parser that accepts the following options:

    cf-ddns-sync.sh --apiToken 145976123897469278364 --zoneId aabbccddeeff --target host1.example.com --source eth0 --source eth1

- `--apiToken`: (Required) Specifies the Cloudflare API Token for API authentication.
- `--zoneId`: (Required) Identifies the DNS Zone ID for the target DNS record, necessary for API calls.
- `--target`: (Required) Provides the hostname for the Cloudflare DNS record, which must already exist in the specified zone.
- `--source`: (Optional) Lists the network interfaces from which to retrieve IPv4 addresses; can accept zero, one, or multiple interfaces.

The script must strictly avoid outputting any content to `stdout`.

When invoked with the `-v` or `--verbose` flags, it may produce specific informative messages (referred to as verbose messages), which should be directed exclusively to `stderr`. 

Ensure that any `curl` command using `POST`, `PUT` or `DELETE` methods does not display the HTTP response in `stdout`.

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

When running in verbose mode, the verbose message must appear before executing the `dig` command. The message should read:

    Getting public IPv4 address for interface $SOURCE_INTERFACE_NAME...

This message must appear for each network interface specified in --source, providing clarity on the interface being processed.



However, if no `--source` argument is provided, the script should skip retrieving the local IPv4 address and directly use the dig command without specifying the `-b` option:

    dig +short txt ch whoami.cloudflare @1.1.1.1 | 
        tr -d '\"'

In verbose mode, the script should display the verbose message "Getting public IPv4 address..." immediately before executing the dig command.



# STEP 2:

Now, the DNS A RECORDS of the specified TARGET hostname must be synchronized with the list of PUBLIC IPV4 ADDRESSES previously obtained.

Lets call them SOURCE_IPV4_ADDRESSES and TARGET_DNS_RECORDS.

FOR EACH SOURCE_IPV4_ADDRESSES we need to INSERT, UPDATE or DELETE a respective DNS A RECORD. 

The UPDATE api call should not be called if the new ip address is the same of the current ip address for a given DNS A RECORD.

The expected final output must be that TARGET_DNS_RECORDS reflect the exact same ipv4 addresses of SOURCE_IPV4_ADDRESSES.





Now, to synchronize the list of DNS A records of the target hostname with the list of public IPv4 addresses obtained in the previous step (lets call it SOURCE_IPV4_ADDRESSES), the script should perform the following steps:

1. **Retrieve Current DNS A Records**: Fetch the current A records for the target hostname (TARGET_DNS_RECORDS) using the Cloudflare API.

2. **Compare and Synchronize DNS A Records**: For each IP in SOURCE_IPV4_ADDRESSES, check if there’s a corresponding DNS A record in TARGET_DNS_RECORDS:
    - Skip: If an existing record already has the correct IP, skip the update to avoid redundant API calls.
    - Insert: If an IP in SOURCE_IPV4_ADDRESSES does not exist in TARGET_DNS_RECORDS, create a new DNS A record for it.
    - Update: If a matching DNS A record exists but with a different IP, update the record with the new IP.
    - Delete Unmatched DNS A Records: For any IP in TARGET_DNS_RECORDS that is not present in SOURCE_IPV4_ADDRESSES, delete the DNS A record to ensure synchronization.

The final outcome should be that TARGET_DNS_RECORDS reflects the exact set of IPv4 addresses in SOURCE_IPV4_ADDRESSES, ensuring the DNS records are accurate and up-to-date with the public IPs of the specified interfaces.
