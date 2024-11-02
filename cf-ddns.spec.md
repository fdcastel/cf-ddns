# Overview

Create two `bash` scripts named `cf-ddns-install.sh` and `cf-ddns-uninstall.sh` as follows.



# First script: `cf-ddns-install.sh`

Create a `bash` script named `cf-ddns-install.sh` to install the `cf-ddns-sync.sh` script as a `systemd` service on Linux.

The script should have a command-line argument parser which accepts the same arguments as the `cf-ddns-sync.sh` script.

The argument parser should validate all inputs and provide usage instructions if `-h` or `--help` is passed.

Upon validation of all arguments, the script execution should proceed as follows:

The script must create a `systemd` SERVICE with the following requirements:
  - The service is required to execute the `cf-ddns-sync.sh` script, passing along all arguments received from the command line.
  - The `cf-ddns-sync.sh` script must to be located in the same directory as this script.
  - The service description should be in the format: `Synchronizes DNS records for $TARGET_NAME`, where $TARGET_NAME is the value from the `--target` argument.
  - The service file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.service`.
  - The service type should be set to `simple`.
  - The service should be configured to redirect both `StandardOutput` and `StandardError` to `syslog`.
  - The service should be configured to use `cf-ddns-$TARGET_NAME` as `SyslogIdentifier`, replacing any '.' with '_'.
  - The service should be configured to execute only after the network is available.

The script must also create a `systemd` TIMER with the following specifications:
  - The timer description should be in the format: `Keeps DNS records for $TARGET_NAME synchronized every minute`.
  - The timer file name (`systemd` unit) should be in the format `cf-ddns-$TARGET_NAME.timer`.
  - The timer should be configured to execute only after the network is available.

The script should then execute the following steps:
  1. Reload the `systemd` manager configuration using `systemctl daemon-reload`.
  2. Stop any pre-existing timer instance with `systemctl stop $SERVICE_NAME`.
  3. Enable and start the timer using `systemctl enable --now $SERVICE_NAME`.

Both systemd units (the service and timer) must be created in the `/etc/systemd/system/` directory.



# Second script: `cf-ddns-uninstall.sh`

Create a `bash` script named `cf-ddns-uninstall.sh`.

This script should revert everything done by the `cf-ddns-install.sh` script, in the reverse order.
