"""
Integration tests against real Cloudflare (T4-T8, T11).

These tests require the env vars:
  - CF_API_TOKEN    — token scoped Zone.DNS:Edit on the test zone
  - CF_ZONE_ID      — test zone id
  - CF_TEST_HOSTNAME — e.g. ci-runner.example.com, a hostname inside the zone

If any are missing, tests are skipped. Every test cleans up the test hostname's
A records (try/finally) to prevent state leaking between runs.

No mocks are used. The script is invoked as a subprocess exactly as a user
would invoke it; the test harness uses a *parallel* direct Cloudflare client
(tests/_cf_client.py) only to seed and verify state.
"""

import json
import os
import pathlib
import subprocess
import sys
import time
import unittest

from tests import _cf_client as cf
from tests._fake_bin import cleanup_fake_bin, make_fake_bin
from tests._loader import require_env, script_path

CACHE_DIR = "/var/cache/cf-ddns"

# RFC 5737 documentation IPs — guaranteed never to route, safe to put in DNS.
FAKE_PUBLIC_IP_A = "192.0.2.10"
FAKE_PUBLIC_IP_B = "192.0.2.20"
FAKE_LOCAL_IP_A = "10.50.0.1"
FAKE_LOCAL_IP_B = "10.50.0.2"


@unittest.skipIf(os.name != "posix", "Integration tests require Linux (dig, ip, systemd paths)")
class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = require_env("CF_API_TOKEN", "CF_ZONE_ID", "CF_TEST_HOSTNAME")
        cls.token = env["CF_API_TOKEN"]
        cls.zone = env["CF_ZONE_ID"]
        cls.host = env["CF_TEST_HOSTNAME"]
        cls.cache_file = os.path.join(CACHE_DIR, cls.host + ".cache")

    def setUp(self):
        # Clean slate: remove any existing A records for the test host and any cache.
        cf.delete_all_a_records(self.token, self.zone, self.host)
        try:
            os.remove(self.cache_file)
        except OSError:
            pass

    def tearDown(self):
        # Unconditional cleanup — don't leak state across runs.
        try:
            cf.delete_all_a_records(self.token, self.zone, self.host)
        except Exception:
            pass
        try:
            os.remove(self.cache_file)
        except OSError:
            pass

    def _run_sync(self, *extra, check=True, env=None):
        cmd = [
            sys.executable, script_path(), "sync",
            "--apiToken", self.token,
            "--zoneId", self.zone,
            "--target", self.host,
            "--debug",
        ] + list(extra)
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=60,
            env=env if env is not None else os.environ.copy(),
        )
        if check and result.returncode != 0:
            self.fail("sync failed: stderr=\n" + result.stderr)
        return result

    def test_T4_fresh_sync_creates_one_record(self):
        result = self._run_sync()
        records = cf.list_a_records(self.token, self.zone, self.host)
        self.assertEqual(len(records), 1,
                         "expected 1 A record, got {}: {}".format(len(records), records))
        # Confirm the stored IP is a valid IPv4 (we trust dig to find the runner's actual IP).
        import ipaddress
        ipaddress.IPv4Address(records[0]["content"])

    def test_T5_idempotent_run_makes_no_changes(self):
        self._run_sync()
        before = cf.list_a_records(self.token, self.zone, self.host)
        self.assertEqual(len(before), 1)
        before_modified = before[0]["modified_on"]
        # Sleep briefly to make sure modified_on would change if anything were written
        time.sleep(2)
        result = self._run_sync()
        after = cf.list_a_records(self.token, self.zone, self.host)
        self.assertEqual(len(after), 1)
        self.assertEqual(after[0]["modified_on"], before_modified,
                         "record was rewritten on idempotent sync")
        self.assertIn("Skipping", result.stderr,
                      "debug run should emit a Skipping line")

    def test_T6_stale_record_is_deleted(self):
        # Seed a bogus A record directly via API.
        cf.create_a_record(self.token, self.zone, self.host, "192.0.2.123", ttl=60)
        self._run_sync()
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = [r["content"] for r in records]
        self.assertNotIn("192.0.2.123", ips,
                         "bogus record was not deleted")

    def test_T7_ttl_correction(self):
        # Let sync create the record with default ttl=60.
        self._run_sync()
        existing = cf.list_a_records(self.token, self.zone, self.host)[0]
        # Directly mutate TTL to something different via a fresh Delete+Create
        # (Cloudflare free tier allows any ttl >= 60).
        cf.delete_record(self.token, self.zone, existing["id"])
        cf.create_a_record(self.token, self.zone, self.host, existing["content"], ttl=300)
        # Remove the cache so sync will refetch from API and detect the mismatch.
        try:
            os.remove(self.cache_file)
        except OSError:
            pass
        # Re-run with ttl=60 — script should Update.
        result = self._run_sync("--ttl", "60")
        self.assertIn("Updating", result.stderr)
        rec = cf.list_a_records(self.token, self.zone, self.host)[0]
        self.assertEqual(rec["ttl"], 60)

    def test_T8_cache_hit_on_second_run(self):
        self._run_sync()
        # Second run should hit the cache.
        result = self._run_sync()
        self.assertIn("(Cached)", result.stderr,
                      "expected '(Cached)' suffix on second sync")


@unittest.skipIf(os.name != "posix", "Multi-WAN tests require POSIX shell for fake bin scripts")
class MultiWanTests(unittest.TestCase):
    """
    M1, M2, M3: cover the headline multi-WAN feature.

    GitHub Actions runners only have one real public IP, so we substitute
    fake `dig` and `ip` binaries via $PATH. The script itself is unmodified
    and Cloudflare is real — only the OS-process boundary tools are faked.
    """

    @classmethod
    def setUpClass(cls):
        env = require_env("CF_API_TOKEN", "CF_ZONE_ID", "CF_TEST_HOSTNAME")
        cls.token = env["CF_API_TOKEN"]
        cls.zone = env["CF_ZONE_ID"]
        cls.host = env["CF_TEST_HOSTNAME"]
        cls.cache_file = os.path.join(CACHE_DIR, cls.host + ".cache")

    def setUp(self):
        cf.delete_all_a_records(self.token, self.zone, self.host)
        try:
            os.remove(self.cache_file)
        except OSError:
            pass
        self.bin_dir = None

    def tearDown(self):
        try:
            cf.delete_all_a_records(self.token, self.zone, self.host)
        except Exception:
            pass
        try:
            os.remove(self.cache_file)
        except OSError:
            pass
        if self.bin_dir:
            cleanup_fake_bin(self.bin_dir)

    def _run_sync(self, sources, env, check=True):
        cmd = [
            sys.executable, script_path(), "sync",
            "--apiToken", self.token,
            "--zoneId", self.zone,
            "--target", self.host,
            "--debug",
        ]
        for s in sources:
            cmd += ["--source", s]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=env)
        if check and result.returncode != 0:
            self.fail("sync failed: stderr=\n" + result.stderr)
        return result

    def test_M1_single_source_A_yields_one_record(self):
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-a": FAKE_LOCAL_IP_A},
            dig_responses={FAKE_LOCAL_IP_A: FAKE_PUBLIC_IP_A},
        )
        result = self._run_sync(["wan-a"], env)
        self.assertIn(
            "Got IPv4 address '{}' for interface 'wan-a'".format(FAKE_PUBLIC_IP_A),
            result.stderr,
        )
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = sorted(r["content"] for r in records)
        self.assertEqual(ips, [FAKE_PUBLIC_IP_A])

    def test_M2_single_source_B_yields_one_record(self):
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-b": FAKE_LOCAL_IP_B},
            dig_responses={FAKE_LOCAL_IP_B: FAKE_PUBLIC_IP_B},
        )
        result = self._run_sync(["wan-b"], env)
        self.assertIn(
            "Got IPv4 address '{}' for interface 'wan-b'".format(FAKE_PUBLIC_IP_B),
            result.stderr,
        )
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = sorted(r["content"] for r in records)
        self.assertEqual(ips, [FAKE_PUBLIC_IP_B])

    def test_M3_dual_source_yields_two_records_round_robin(self):
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-a": FAKE_LOCAL_IP_A, "wan-b": FAKE_LOCAL_IP_B},
            dig_responses={
                FAKE_LOCAL_IP_A: FAKE_PUBLIC_IP_A,
                FAKE_LOCAL_IP_B: FAKE_PUBLIC_IP_B,
            },
        )
        self._run_sync(["wan-a", "wan-b"], env)
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = sorted(r["content"] for r in records)
        self.assertEqual(ips, sorted([FAKE_PUBLIC_IP_A, FAKE_PUBLIC_IP_B]),
                         "expected round-robin A records for both WANs")

    def test_M4_dual_source_with_duplicate_public_ip_dedupes(self):
        """Two WANs egressing through the same public IP -> single A record."""
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-a": FAKE_LOCAL_IP_A, "wan-b": FAKE_LOCAL_IP_B},
            dig_responses={
                FAKE_LOCAL_IP_A: FAKE_PUBLIC_IP_A,
                FAKE_LOCAL_IP_B: FAKE_PUBLIC_IP_A,  # same public IP
            },
        )
        self._run_sync(["wan-a", "wan-b"], env)
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = sorted(r["content"] for r in records)
        self.assertEqual(ips, [FAKE_PUBLIC_IP_A])

    def test_M5_transition_dual_to_single_removes_dropped_ip(self):
        """
        WAN-B goes offline between syncs: starting state is A+B (two records),
        next sync sees only WAN-A and must delete the WAN-B record.
        """
        # First sync: both WANs alive.
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-a": FAKE_LOCAL_IP_A, "wan-b": FAKE_LOCAL_IP_B},
            dig_responses={
                FAKE_LOCAL_IP_A: FAKE_PUBLIC_IP_A,
                FAKE_LOCAL_IP_B: FAKE_PUBLIC_IP_B,
            },
        )
        self._run_sync(["wan-a", "wan-b"], env)
        cleanup_fake_bin(self.bin_dir)

        # Second sync: WAN-B has no public IP (e.g. cable unplugged).
        self.bin_dir, env = make_fake_bin(
            ip_responses={"wan-a": FAKE_LOCAL_IP_A, "wan-b": FAKE_LOCAL_IP_B},
            dig_responses={
                FAKE_LOCAL_IP_A: FAKE_PUBLIC_IP_A,
                # FAKE_LOCAL_IP_B not mapped -> empty dig output -> interface ignored
            },
        )
        result = self._run_sync(["wan-a", "wan-b"], env)
        self.assertIn(
            "Removing '{}' from".format(FAKE_PUBLIC_IP_B), result.stderr
        )
        records = cf.list_a_records(self.token, self.zone, self.host)
        ips = sorted(r["content"] for r in records)
        self.assertEqual(ips, [FAKE_PUBLIC_IP_A])


if __name__ == "__main__":
    unittest.main()
