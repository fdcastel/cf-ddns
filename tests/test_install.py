"""
T9: Install/uninstall dry-run tests using CF_DDNS_ETC_DIR.

These tests exercise the real install/uninstall/status code paths without
touching /etc/ or invoking systemd. No Cloudflare calls are made — install
only writes files and does not hit the network.
"""

import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

from tests._loader import script_path, TMP_DIR


@unittest.skipIf(os.name != "posix", "cf-ddns.py requires POSIX (fcntl)")
class InstallDryRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cf-ddns-etc-", dir=str(TMP_DIR))
        self.env = os.environ.copy()
        self.env["CF_DDNS_ETC_DIR"] = self.tmp
        self.target = "test.example.com"
        self.token = "fake-token-not-a-secret"
        self.zone = "00000000000000000000000000000000"

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, *args):
        return subprocess.run(
            [sys.executable, script_path()] + list(args),
            capture_output=True, text=True, timeout=30, env=self.env,
        )

    def _install(self, *extra):
        return self._run(
            "install",
            "--apiToken", self.token,
            "--zoneId", self.zone,
            "--target", self.target,
            *extra,
        )

    def test_install_creates_unit_files_and_env(self):
        result = self._install()
        self.assertEqual(result.returncode, 0, msg=result.stderr)

        systemd_dir = os.path.join(self.tmp, "systemd", "system")
        secrets_dir = os.path.join(self.tmp, "cf-ddns")
        service = os.path.join(systemd_dir, "cf-ddns-{}.service".format(self.target))
        timer = os.path.join(systemd_dir, "cf-ddns-{}.timer".format(self.target))
        env_file = os.path.join(secrets_dir, "{}.env".format(self.target))

        self.assertTrue(os.path.exists(service), "service file not created")
        self.assertTrue(os.path.exists(timer), "timer file not created")
        self.assertTrue(os.path.exists(env_file), "env file not created")

    def test_service_file_references_env_token_not_inline(self):
        self._install()
        service = os.path.join(
            self.tmp, "systemd", "system", "cf-ddns-{}.service".format(self.target)
        )
        with open(service) as f:
            content = f.read()
        # Token must NOT appear verbatim in the service file
        self.assertNotIn(self.token, content,
                         "API token leaked into service file")
        # The ExecStart line must reference the env variable
        self.assertIn("${CF_API_TOKEN}", content)
        # EnvironmentFile must be set
        self.assertIn("EnvironmentFile=", content)
        # Standard fields
        self.assertIn("Type=oneshot", content)
        self.assertIn("TimeoutSec=30", content)
        self.assertRegex(content, r"Description=Synchronizes DNS records for " + re.escape(self.target))

    def test_timer_file_has_accuracy_1min(self):
        self._install()
        timer = os.path.join(
            self.tmp, "systemd", "system", "cf-ddns-{}.timer".format(self.target)
        )
        with open(timer) as f:
            content = f.read()
        self.assertIn("AccuracySec=1min", content)
        self.assertIn("OnUnitActiveSec=1min", content)
        self.assertRegex(content,
                         r"Description=Keeps DNS records for " + re.escape(self.target)
                         + r" synchronized every minute")

    def test_env_file_contains_token_and_is_mode_0600_on_linux(self):
        self._install()
        env_file = os.path.join(
            self.tmp, "cf-ddns", "{}.env".format(self.target)
        )
        with open(env_file) as f:
            content = f.read()
        self.assertIn("CF_API_TOKEN={}".format(self.token), content)

        if os.name == "posix":
            mode = stat.S_IMODE(os.stat(env_file).st_mode)
            self.assertEqual(mode, 0o600,
                             "env file should be mode 0600, got {:o}".format(mode))

    def test_invalid_target_rejected(self):
        result = self._run(
            "install",
            "--apiToken", self.token,
            "--zoneId", self.zone,
            "--target", "../etc/passwd",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Invalid target hostname", result.stderr)

    def test_status_shows_unit_paths_and_redacted_token(self):
        self._install()
        result = self._run("status", "--target", self.target)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("cf-ddns-{}.service".format(self.target), result.stdout)
        self.assertIn("cf-ddns-{}.timer".format(self.target), result.stdout)
        self.assertIn("CF_API_TOKEN=***", result.stdout)
        self.assertNotIn(self.token, result.stdout)

    def test_status_fails_when_not_installed(self):
        result = self._run("status", "--target", "nonexistent.example.com")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not installed", result.stderr)

    def test_uninstall_removes_all_files(self):
        self._install()
        result = self._run("uninstall", "--target", self.target)
        self.assertEqual(result.returncode, 0, msg=result.stderr)

        systemd_dir = os.path.join(self.tmp, "systemd", "system")
        secrets_dir = os.path.join(self.tmp, "cf-ddns")
        for p in (
            os.path.join(systemd_dir, "cf-ddns-{}.service".format(self.target)),
            os.path.join(systemd_dir, "cf-ddns-{}.timer".format(self.target)),
            os.path.join(secrets_dir, "{}.env".format(self.target)),
        ):
            self.assertFalse(os.path.exists(p), "left behind: " + p)

    def test_uninstall_when_nothing_installed_is_nonfatal(self):
        result = self._run("uninstall", "--target", "never-installed.example.com")
        self.assertEqual(result.returncode, 0, msg=result.stderr)


if __name__ == "__main__":
    unittest.main()
