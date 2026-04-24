"""
Unit tests for cf-ddns.py. No network, no systemd, no real filesystem outside
tempdirs. Loads the script as a module via importlib.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests._loader import load_cfddns, script_path, TMP_DIR


class HostnameValidationTests(unittest.TestCase):
    def setUp(self):
        self.cfddns = load_cfddns()

    def test_valid_hostnames(self):
        for name in ["example.com", "host-1.example.com", "a.b.c", "ABC123"]:
            self.assertIsNotNone(
                self.cfddns.HOSTNAME_RE.match(name),
                "expected {!r} to be valid".format(name),
            )

    def test_invalid_hostnames_rejected(self):
        for name in ["../etc/passwd", "host/evil", "host;rm", "", "host with space"]:
            self.assertIsNone(
                self.cfddns.HOSTNAME_RE.match(name),
                "expected {!r} to be rejected".format(name),
            )

    def test_validate_target_exits_on_invalid(self):
        with self.assertRaises(SystemExit) as ctx:
            self.cfddns.validate_target("../evil")
        self.assertEqual(ctx.exception.code, 1)


class Ipv4RegexTests(unittest.TestCase):
    """
    The spec requires parsing `ip -4 -oneline address show $IFACE` output via
    the regex and validating the match via ipaddress.IPv4Address.
    """

    def setUp(self):
        self.cfddns = load_cfddns()

    def test_extracts_first_ipv4_from_ip_command_output(self):
        sample = (
            "2: eth0    inet 203.0.113.42/24 brd 203.0.113.255 "
            "scope global dynamic eth0\\       valid_lft 3421sec preferred_lft 3421sec"
        )
        m = self.cfddns.IPV4_RE.search(sample)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(0), "203.0.113.42")

    def test_rejects_non_ip_strings(self):
        for bad in ["foo.bar.baz.qux", "999.999.999.999"]:
            # regex may match 999.999.999.999 syntactically; ipaddress must reject.
            m = self.cfddns.IPV4_RE.search(bad)
            if m:
                import ipaddress
                with self.assertRaises(ValueError):
                    ipaddress.IPv4Address(m.group(0))


class CacheRoundtripTests(unittest.TestCase):
    def setUp(self):
        self.cfddns = load_cfddns()
        self.tmp = tempfile.mkdtemp(dir=str(TMP_DIR))
        self.cache_path = os.path.join(self.tmp, "host.example.com.cache")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_write_then_read_returns_same_records(self):
        records = [
            {"id": "abc", "content": "5.6.7.8", "ttl": 60, "type": "A", "name": "h"},
            {"id": "def", "content": "1.2.3.4", "ttl": 60, "type": "A", "name": "h"},
        ]
        self.cfddns.write_cache(self.cache_path, records)
        out = self.cfddns.read_cache(self.cache_path)
        self.assertIsNotNone(out)
        # records should be sorted by IP ascending
        self.assertEqual([r["content"] for r in out], ["1.2.3.4", "5.6.7.8"])

    def test_atomic_write_leaves_no_tmp_file(self):
        self.cfddns.write_cache(self.cache_path, [{"content": "1.2.3.4", "ttl": 60}])
        self.assertTrue(os.path.exists(self.cache_path))
        self.assertFalse(os.path.exists(self.cache_path + ".tmp"))

    def test_read_missing_cache_returns_none(self):
        self.assertIsNone(self.cfddns.read_cache("/nonexistent/path.cache"))

    def test_read_corrupt_cache_returns_none(self):
        with open(self.cache_path, "w") as f:
            f.write("not-json{{{")
        self.assertIsNone(self.cfddns.read_cache(self.cache_path))


class EtcDirsOverrideTests(unittest.TestCase):
    def setUp(self):
        self.cfddns = load_cfddns()
        self._saved = os.environ.pop("CF_DDNS_ETC_DIR", None)

    def tearDown(self):
        if self._saved is not None:
            os.environ["CF_DDNS_ETC_DIR"] = self._saved
        else:
            os.environ.pop("CF_DDNS_ETC_DIR", None)

    def test_default_paths(self):
        systemd, secrets, override = self.cfddns.etc_dirs()
        self.assertEqual(systemd, "/etc/systemd/system")
        self.assertEqual(secrets, "/etc/cf-ddns")
        self.assertFalse(override)

    def test_override_paths(self):
        os.environ["CF_DDNS_ETC_DIR"] = "/tmp/fake-etc"
        systemd, secrets, override = self.cfddns.etc_dirs()
        self.assertEqual(systemd, os.path.join("/tmp/fake-etc", "systemd", "system"))
        self.assertEqual(secrets, os.path.join("/tmp/fake-etc", "cf-ddns"))
        self.assertTrue(override)


@unittest.skipIf(os.name != "posix", "cf-ddns.py requires POSIX (fcntl)")
class CliBehaviorTests(unittest.TestCase):
    """End-to-end CLI surface: run the real script as a subprocess."""

    def _run(self, *args, env=None):
        cmd = [sys.executable, script_path()] + list(args)
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            env=env if env is not None else os.environ.copy(),
        )

    def test_help_exits_zero(self):
        result = self._run("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("sync", result.stdout)

    def test_sync_help_lists_args(self):
        result = self._run("sync", "--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--apiToken", result.stdout)
        self.assertIn("--zoneId", result.stdout)
        self.assertIn("--target", result.stdout)

    def test_missing_required_args_exit_2(self):
        result = self._run("sync")
        self.assertEqual(result.returncode, 2)

    def test_unknown_command_exit_2(self):
        result = self._run("bogus")
        self.assertEqual(result.returncode, 2)

    def test_no_command_exit_2(self):
        result = self._run()
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
