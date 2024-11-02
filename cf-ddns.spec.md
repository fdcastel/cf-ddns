# Overview

Create a `bash` script named `cf-ddns.sh` to install or uninstall the `cf-ddns-sync.sh` script as a `systemd` service on Linux.

This script should include a command-line argument parser with support for the following options:

    cf-ddns.sh install --target host1.example.com [extra-arguments]
    cf-ddns.sh uninstall --target host1.example.com

The script expects a `command` as the first argument. There are two possible commands:

  - `install`: This command accept additional arguments supported by the `cf-ddns-sync.sh` script.
  - `uninstall`: This command should not accept any additional arguments.

Both commands REQUIRE a `--target` argument, which serves as a unique identifier for multiple instances of the service.

The `install` command have the following additional arguments:
 
  - `--apiToken`: (Required)
  - `--zoneId`: (Required)
  - `--source`: (Optional)
  - `--ttl`: (Optional)

These arguments should be stored to be passed as arguments to the `cf-ddns-sync.sh` script.

The argument parser should validate all inputs and provide usage instructions if `-h` or `--help` is passed. 

Upon validation of all arguments, the script execution should proceed as follows:



# `Install` command

The command must create a `systemd` SERVICE to execute `cf-ddns-sync.sh` script with the following requirements:
  - The service description should be in the format: `Synchronizes DNS records for $TARGET_NAME`, where $TARGET_NAME is the value from the `--target` argument.
  - The service file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.service`.
  - The service type should be set to `simple`.
  - All arguments to this script (except the first argument, install, which specifies the command) should be passed to `cf-ddns-sync.sh`.
  - The `cf-ddns-sync.sh` script is assumed to be located in the same directory as the `cf-ddns.sh` script.
  - The service should be configured to execute only after the network is available.

The command must also create a `systemd` TIMER with the following specifications:
  - The timer description should be in the format: `Keeps DNS records for $TARGET_NAME synchronized every minute`.
  - The timer file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.timer`.
  - The timer should be configured to execute only after the network is available.

The command should then execute the following steps:
  1. Reload the `systemd` manager configuration using `systemctl daemon-reload`.
  2. Stop any pre-existing timer instance with `systemctl stop $SERVICE_NAME`.
  3. Enable and start the timer using `systemctl enable --now $SERVICE_NAME`.

Both systemd units (the service and timer) must be created in the `/etc/systemd/system/` directory.



# `Uninstall` command

This command should revert everything done by the `install` command, in the reverse order.
