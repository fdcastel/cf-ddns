I'll help you create the install and uninstall scripts according to the specification. Let me break this down into steps:

Create `cf-ddns-install.sh`:

1.Parse and validate command line arguments
- Create systemd service file with specified requirements
- Create systemd timer file
- Install and enable the service/timer

2.Create `cf-ddns-uninstall.sh`:
- Find and stop any running timers
- Disable and remove the service/timer files
- Reload systemd

Here are the scripts:

`cf-ddns-install.sh`
Creates systemd service and timer units based on command line arguments.

`cf-ddns-uninstall.sh`
Removes systemd service and timer units for a given target.

The install script accepts the same arguments as cf-ddns-sync.sh and creates the necessary systemd units. The uninstall script only needs the target hostname to remove the corresponding units.

Make sure to:

1.Place both scripts in the same directory as cf-ddns-sync.sh
2.Make them executable: `chmod +x cf-ddns-{install,uninstall}.sh`
3.Run the install script with root privileges since it needs to write to `/etc/systemd/system/`
