# Contributing to cf-ddns

## The spec-driven workflow

This project is an AI-assisted-development research case study. The rule is:

> **`cf-ddns.py` is generated from `cf-ddns.spec.md`.**
> Do not edit `cf-ddns.py` directly. Edit the spec, then regenerate.

### Why

Hand-patching `cf-ddns.py` defeats the research property that the script can be reproduced from a single human-written specification. Small tweaks accumulate into a codebase that no longer matches its spec, and the case study becomes meaningless.

### How to change behavior

1. Edit `cf-ddns.spec.md`.
2. Run a fresh AI-assisted regeneration. Pass *only* the updated spec to an agent (e.g. Claude Code, Copilot, or a standalone model) and ask it to produce `cf-ddns.py` from scratch. Overwrite the old file.
3. Run the test suite (`python -m unittest -v tests.test_unit tests.test_install`) and iterate on spec wording until tests pass.
4. Commit the spec change, the regenerated script, and (if needed) new tests in the same commit. Note the model/agent used in the commit body, for example:

   ```
   Add flock on cache file (S7)

   Regenerated cf-ddns.py from cf-ddns.spec.md using Claude Opus 4.7.
   ```

### What you *can* edit directly

- `cf-ddns.spec.md` — the source of truth.
- `tests/` — tests are infrastructure, not part of the research artifact.
- `README.md`, this file — documentation.
- `.github/workflows/` — CI configuration.

### What you must regenerate

- `cf-ddns.py` — only ever an emission from the spec.

## Running tests

Tests use `uv` to manage Python; no virtualenv setup needed.

```bash
# Unit tests + install dry-run tests — no network, always runs.
uv run --no-project --python 3.12 python -m unittest -v tests.test_unit tests.test_install

# Integration tests — require real Cloudflare credentials and a Linux host.
export CF_API_TOKEN=...
export CF_ZONE_ID=...
export CF_TEST_HOSTNAME=ci-test.example.com
sudo mkdir -p /var/cache/cf-ddns && sudo chmod 1777 /var/cache/cf-ddns
uv run --no-project --python 3.12 python -m unittest -v tests.test_integration
```

Integration tests write and delete real DNS records in the configured zone. Use a dedicated test zone, never production. The multi-WAN tests (`MultiWanTests`) substitute fake `dig` and `ip` binaries via `$PATH` so they can simulate two distinct public IPs on a single-interface CI runner; the script itself runs unmodified and Cloudflare is real.

## CI setup

See `.github/workflows/ci.yml`. To enable integration tests on this repository, set three repository secrets:

| Secret             | Value                                                      |
| ------------------ | ---------------------------------------------------------- |
| `CF_API_TOKEN`     | Cloudflare API token with `Zone.DNS:Edit` on the test zone |
| `CF_ZONE_ID`      | Zone ID of the test zone                                    |
| `CF_TEST_HOSTNAME` | A hostname inside the test zone, e.g. `ci.example.com`      |

Without these secrets the integration job skips gracefully.
