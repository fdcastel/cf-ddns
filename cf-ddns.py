#!/usr/bin/env python3
"""cf-ddns: synchronize Cloudflare DNS A records with interface IPv4 addresses."""

import argparse
import fcntl
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CF_API_BASE = "https://api.cloudflare.com/client/v4"
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
CACHE_DIR = "/var/cache/cf-ddns"

LOG_VERBOSE = False
LOG_DEBUG = False


def log_error(msg):
    print(msg, file=sys.stderr)


def log_change(msg):
    if LOG_VERBOSE or LOG_DEBUG:
        print(msg, file=sys.stderr)


def log_debug(msg):
    if LOG_DEBUG:
        print(msg, file=sys.stderr)


def validate_target(target):
    if not HOSTNAME_RE.match(target):
        log_error("ERROR: Invalid target hostname '{}'.".format(target))
        sys.exit(1)


def etc_dirs():
    override = os.environ.get("CF_DDNS_ETC_DIR")
    if override:
        return (
            os.path.join(override, "systemd", "system"),
            os.path.join(override, "cf-ddns"),
            True,
        )
    return ("/etc/systemd/system", "/etc/cf-ddns", False)


def get_local_ipv4(iface):
    try:
        out = subprocess.check_output(
            ["ip", "-4", "-oneline", "address", "show", iface],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", "replace")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    m = IPV4_RE.search(out)
    if not m:
        return None
    try:
        ipaddress.IPv4Address(m.group(0))
    except ValueError:
        return None
    return m.group(0)


def dig_public_ip(local_ip):
    cmd = ["dig"]
    if local_ip:
        cmd += ["-b", local_ip]
    cmd += ["+short", "+time=3", "+tries=1", "txt", "ch", "whoami.cloudflare", "@1.0.0.1"]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode("utf-8", "replace").strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if not out:
        return None
    return out.replace('"', '').strip() or None


def gather_source_ips(sources):
    ips = []
    seen = set()
    if not sources:
        ip = dig_public_ip(None)
        log_debug("Got IPv4 address '{}'.".format(ip))
        if ip and ip not in seen:
            try:
                ipaddress.IPv4Address(ip)
                ips.append(ip)
                seen.add(ip)
            except ValueError:
                pass
    else:
        for iface in sources:
            local = get_local_ipv4(iface)
            if not local:
                continue
            ip = dig_public_ip(local)
            log_debug("Got IPv4 address '{}' for interface '{}'.".format(ip, iface))
            if not ip:
                continue
            try:
                ipaddress.IPv4Address(ip)
            except ValueError:
                continue
            if ip in seen:
                continue
            seen.add(ip)
            ips.append(ip)
    if not ips:
        log_error("ERROR: Cannot get public IPv4 address.")
        sys.exit(1)
    return sorted(ips)


def cf_request(method, path, token, payload=None):
    url = CF_API_BASE + path
    data = None
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            doc = json.loads(body)
        except ValueError:
            log_error("ERROR: HTTP {} from Cloudflare.".format(e.code))
            sys.exit(1)
        handle_cf_error(doc)
        sys.exit(1)
    except urllib.error.URLError as e:
        log_error("ERROR: Network error: {}: {}.".format(type(e).__name__, e.reason))
        sys.exit(1)
    except (TimeoutError, OSError) as e:
        log_error("ERROR: Network error: {}: {}.".format(type(e).__name__, e))
        sys.exit(1)
    try:
        doc = json.loads(body)
    except ValueError:
        log_error("ERROR: Invalid JSON response from Cloudflare.")
        sys.exit(1)
    if not doc.get("success", False):
        handle_cf_error(doc)
        sys.exit(1)
    return doc


def handle_cf_error(doc):
    errors = doc.get("errors") or []
    if errors:
        first = errors[0]
        log_error("ERROR: {} (code: {}).".format(first.get("message", ""), first.get("code", "")))
    else:
        log_error("ERROR: Cloudflare API call failed.")


def fetch_records_from_api(zone_id, target, token):
    path = "/zones/{}/dns_records?type=A&name={}".format(zone_id, target)
    doc = cf_request("GET", path, token)
    records = doc.get("result") or []
    return sorted(records, key=lambda r: r.get("content", ""))


def read_cache(cache_path):
    try:
        with open(cache_path, "r") as f:
            doc = json.load(f)
        recs = doc.get("records") or []
        return sorted(recs, key=lambda r: r.get("content", ""))
    except (OSError, ValueError):
        return None


def write_cache(cache_path, records):
    try:
        Path(os.path.dirname(cache_path)).mkdir(parents=True, exist_ok=True)
        sorted_recs = sorted(records, key=lambda r: r.get("content", ""))
        doc = {"timestamp": int(time.time()), "records": sorted_recs}
        tmp = cache_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f)
        os.replace(tmp, cache_path)
    except OSError as e:
        log_error("WARNING: Failed to update cache: {}".format(e))


def cmd_sync(args):
    global LOG_VERBOSE, LOG_DEBUG
    LOG_DEBUG = args.debug
    LOG_VERBOSE = args.verbose or args.debug

    validate_target(args.target)

    source_ips = gather_source_ips(args.source)

    Path(CACHE_DIR).mkdir(parents=True, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, args.target + ".cache")

    try:
        lock_fd = os.open(cache_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:
        log_error("ERROR: Cannot open cache file: {}.".format(e))
        sys.exit(1)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)

    cached = read_cache(cache_path)
    use_cache = False
    if cached is not None:
        cached_ips = [r.get("content") for r in cached]
        if len(cached_ips) == len(source_ips) and all(ip in cached_ips for ip in source_ips):
            use_cache = True

    if use_cache:
        target_records = cached
        suffix = " (Cached)"
    else:
        target_records = fetch_records_from_api(args.zoneId, args.target, args.apiToken)
        suffix = ""

    ip_list = ", ".join(r.get("content", "") for r in target_records)
    log_debug("DNS A records for '{}' = [{}]{}".format(args.target, ip_list, suffix))

    target_by_ip = {r.get("content"): r for r in target_records}
    source_set = set(source_ips)
    target_set = set(target_by_ip.keys())

    new_records = []

    for ip in sorted(source_set):
        if ip in target_set:
            existing = target_by_ip[ip]
            if existing.get("ttl") == args.ttl:
                log_debug("Skipping '{}'.".format(ip))
                new_records.append(existing)
            else:
                log_change("Updating '{}' in '{}'.".format(ip, args.target))
                payload = {"type": "A", "name": args.target, "content": ip, "ttl": args.ttl}
                cf_request(
                    "PUT",
                    "/zones/{}/dns_records/{}".format(args.zoneId, existing.get("id")),
                    args.apiToken,
                    payload,
                )
                refreshed = dict(existing)
                refreshed["ttl"] = args.ttl
                new_records.append(refreshed)
        else:
            log_change("Adding '{}' to '{}'.".format(ip, args.target))
            payload = {"type": "A", "name": args.target, "content": ip, "ttl": args.ttl}
            doc = cf_request(
                "POST",
                "/zones/{}/dns_records".format(args.zoneId),
                args.apiToken,
                payload,
            )
            created = doc.get("result") or {}
            new_records.append(created)

    for ip in sorted(target_set - source_set):
        existing = target_by_ip[ip]
        log_change("Removing '{}' from '{}'.".format(ip, args.target))
        cf_request(
            "DELETE",
            "/zones/{}/dns_records/{}".format(args.zoneId, existing.get("id")),
            args.apiToken,
        )

    write_cache(cache_path, new_records)


def write_secrets(secrets_dir, target, token):
    Path(secrets_dir).mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(secrets_dir, 0o700)
    except OSError:
        pass
    path = os.path.join(secrets_dir, target + ".env")
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, ("CF_API_TOKEN=" + token + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def build_exec_start(script_path, args):
    parts = [script_path, "sync", "--apiToken", "${CF_API_TOKEN}",
             "--zoneId", args.zoneId, "--target", args.target,
             "--ttl", str(args.ttl), "--verbose"]
    for s in args.source or []:
        parts += ["--source", s]
    return " ".join(parts)


def cmd_install(args):
    validate_target(args.target)
    systemd_dir, secrets_dir, override = etc_dirs()

    write_secrets(secrets_dir, args.target, args.apiToken)

    script_path = os.path.realpath(__file__)
    exec_start = build_exec_start(script_path, args)
    env_file = os.path.join(secrets_dir, args.target + ".env")

    service_unit = (
        "[Unit]\n"
        "Description=Synchronizes DNS records for {target}\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "EnvironmentFile={env_file}\n"
        "ExecStart={exec_start}\n"
        "TimeoutSec=30\n"
        "StandardOutput=journal\n"
        "StandardError=journal\n"
    ).format(target=args.target, env_file=env_file, exec_start=exec_start)

    timer_unit = (
        "[Unit]\n"
        "Description=Keeps DNS records for {target} synchronized every minute\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n"
        "\n"
        "[Timer]\n"
        "OnBootSec=1min\n"
        "OnUnitActiveSec=1min\n"
        "AccuracySec=1min\n"
        "Unit=cf-ddns-{target}.service\n"
        "\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    ).format(target=args.target)

    Path(systemd_dir).mkdir(parents=True, exist_ok=True)
    service_path = os.path.join(systemd_dir, "cf-ddns-{}.service".format(args.target))
    timer_path = os.path.join(systemd_dir, "cf-ddns-{}.timer".format(args.target))
    with open(service_path, "w") as f:
        f.write(service_unit)
    with open(timer_path, "w") as f:
        f.write(timer_unit)

    if not override:
        subprocess.call(["systemctl", "daemon-reload"])
        subprocess.call(["systemctl", "stop", "cf-ddns-{}.timer".format(args.target)])
        subprocess.call(["systemctl", "enable", "--now", "cf-ddns-{}.timer".format(args.target)])


def cmd_uninstall(args):
    validate_target(args.target)
    systemd_dir, secrets_dir, override = etc_dirs()

    if not override:
        subprocess.call(["systemctl", "disable", "--now", "cf-ddns-{}.timer".format(args.target)])
        subprocess.call(["systemctl", "stop", "cf-ddns-{}.service".format(args.target)])

    for path in (
        os.path.join(systemd_dir, "cf-ddns-{}.timer".format(args.target)),
        os.path.join(systemd_dir, "cf-ddns-{}.service".format(args.target)),
        os.path.join(secrets_dir, args.target + ".env"),
    ):
        try:
            os.remove(path)
        except OSError:
            pass

    if not override:
        subprocess.call(["systemctl", "daemon-reload"])


def cmd_status(args):
    validate_target(args.target)
    systemd_dir, secrets_dir, override = etc_dirs()

    service_path = os.path.join(systemd_dir, "cf-ddns-{}.service".format(args.target))
    timer_path = os.path.join(systemd_dir, "cf-ddns-{}.timer".format(args.target))
    env_path = os.path.join(secrets_dir, args.target + ".env")

    if not os.path.exists(service_path):
        log_error("ERROR: Service for target '{}' is not installed.".format(args.target))
        sys.exit(1)

    if override:
        print(service_path)
        print(timer_path)
        try:
            with open(env_path, "r") as f:
                for line in f:
                    line = line.rstrip("\n")
                    if line.startswith("CF_API_TOKEN="):
                        print("CF_API_TOKEN=***")
                    else:
                        print(line)
        except OSError:
            pass
    else:
        subprocess.call(["systemctl", "status", "cf-ddns-{}.timer".format(args.target)])
        subprocess.call(["systemctl", "status", "cf-ddns-{}.service".format(args.target)])
        subprocess.call(["journalctl", "-u", "cf-ddns-{}.service".format(args.target), "-n", "20", "--no-pager"])


def build_parser():
    p = argparse.ArgumentParser(prog="cf-ddns")
    sub = p.add_subparsers(dest="command")
    sub.required = True

    sp = sub.add_parser("sync")
    sp.add_argument("--apiToken", required=True)
    sp.add_argument("--zoneId", required=True)
    sp.add_argument("--target", required=True)
    sp.add_argument("--source", action="append", default=[])
    sp.add_argument("--ttl", type=int, default=60)
    sp.add_argument("-v", "--verbose", action="store_true")
    sp.add_argument("--debug", action="store_true")
    sp.set_defaults(func=cmd_sync)

    ip = sub.add_parser("install")
    ip.add_argument("--apiToken", required=True)
    ip.add_argument("--zoneId", required=True)
    ip.add_argument("--target", required=True)
    ip.add_argument("--source", action="append", default=[])
    ip.add_argument("--ttl", type=int, default=60)
    ip.set_defaults(func=cmd_install)

    up = sub.add_parser("uninstall")
    up.add_argument("--target", required=True)
    up.set_defaults(func=cmd_uninstall)

    st = sub.add_parser("status")
    st.add_argument("--target", required=True)
    st.set_defaults(func=cmd_status)

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
