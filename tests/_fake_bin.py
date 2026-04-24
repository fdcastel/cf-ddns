"""
Build fake `dig` and `ip` executables in a tempdir, so that integration tests
can deterministically simulate multiple WAN interfaces with distinct public IPs
on a CI runner that has only one real network egress.

The faked tools are at the OS-process boundary — `cf-ddns.py` itself is
unmodified and execve's these binaries exactly as it would the real ones.
Real Cloudflare is still used for the actual DNS sync.
"""

import os
import stat
import tempfile

from tests._loader import TMP_DIR


def make_fake_bin(ip_responses, dig_responses, default_dig_response=None):
    """
    Create a tempdir under ./tmp/.test/ containing fake `ip` and `dig` shell
    scripts. Returns (bin_dir, env) where env is os.environ with PATH prepended.

    Args:
        ip_responses: dict mapping interface_name -> local_ipv4 string.
                      Unknown interfaces produce empty output (the script then
                      treats the interface as having no IP).
        dig_responses: dict mapping local_ipv4 -> public_ipv4 string. The
                       script invokes `dig -b LOCAL_IP ...` and the fake
                       returns the configured public IP.
        default_dig_response: when the script invokes `dig` without `-b`
                              (no --source argument), this value is returned.
                              If None, the no-source code path is not exercised.

    Tests must call cleanup_fake_bin(bin_dir) in tearDown.
    """
    bin_dir = tempfile.mkdtemp(prefix="fake-bin-", dir=str(TMP_DIR))

    # ----- fake `ip` -----
    ip_lines = ['#!/usr/bin/env bash', 'iface="${@: -1}"', 'case "$iface" in']
    for iface, local_ip in ip_responses.items():
        ip_lines.append(
            '  {iface}) echo "2: {iface}    inet {local_ip}/24 brd 10.0.0.255 '
            'scope global {iface}"; exit 0;;'.format(iface=iface, local_ip=local_ip)
        )
    ip_lines.append('  *) exit 1;;')
    ip_lines.append('esac')
    _write_executable(os.path.join(bin_dir, "ip"), "\n".join(ip_lines) + "\n")

    # ----- fake `dig` -----
    dig_lines = [
        '#!/usr/bin/env bash',
        'local_ip=""',
        'while [ $# -gt 0 ]; do',
        '  if [ "$1" = "-b" ]; then shift; local_ip="$1"; fi',
        '  shift',
        'done',
        'case "$local_ip" in',
    ]
    for local_ip, public_ip in dig_responses.items():
        dig_lines.append(
            '  {local}) echo \'"{public}"\'; exit 0;;'.format(local=local_ip, public=public_ip)
        )
    if default_dig_response is not None:
        dig_lines.append(
            '  "") echo \'"{public}"\'; exit 0;;'.format(public=default_dig_response)
        )
    dig_lines.append('  *) exit 0;;')  # empty output -> interface skipped
    dig_lines.append('esac')
    _write_executable(os.path.join(bin_dir, "dig"), "\n".join(dig_lines) + "\n")

    env = os.environ.copy()
    env["PATH"] = bin_dir + os.pathsep + env.get("PATH", "")
    return bin_dir, env


def cleanup_fake_bin(bin_dir):
    import shutil
    shutil.rmtree(bin_dir, ignore_errors=True)


def _write_executable(path, content):
    with open(path, "w", newline="\n") as f:
        f.write(content)
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
