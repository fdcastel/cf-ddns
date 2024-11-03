I'll help create the installation and uninstallation scripts based on the specification. Here's the step-by-step solution:

1. Create the installation script that accepts and validates arguments
2. Create systemd service and timer units based on the arguments
3. Create the uninstallation script that cleanly removes everything

### cf-ddns-install.sh

Creates a systemd service and timer for the cf-ddns-sync.py script, handling command line arguments and installation.

### cf-ddns-uninstall.sh

Removes the systemd service and timer created by the installation script.

The installation script will:
1. Parse and validate command line arguments
2. Create systemd service and timer units
3. Enable and start the timer

The uninstallation script will:
1. Stop and disable the service/timer
2. Remove the systemd unit files
3. Reload systemd configuration
