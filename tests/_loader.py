"""Shared helpers for loading cf-ddns.py as an importable module."""

import importlib.util
import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "cf-ddns.py"
TMP_DIR = REPO_ROOT / "tmp" / ".test"
TMP_DIR.mkdir(parents=True, exist_ok=True)


def load_cfddns():
    """Load cf-ddns.py as a module. Skips the calling test on non-POSIX systems
    (the script imports fcntl, which only exists on Linux/macOS)."""
    try:
        spec = importlib.util.spec_from_file_location("cfddns", SCRIPT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except ImportError as e:
        import unittest
        raise unittest.SkipTest("cf-ddns.py requires POSIX ({})".format(e))


def script_path():
    return str(SCRIPT_PATH)


def require_env(*names):
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        import unittest
        raise unittest.SkipTest(
            "Skipping integration tests; missing env: " + ", ".join(missing)
        )
    return {n: os.environ[n] for n in names}
