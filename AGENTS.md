# AGENTS.md

Instructions for AI coding agents operating on this repository.

## Golden rule

**`cf-ddns.py` is generated from `cf-ddns.spec.md`. Never hand-edit the script.**

To change behavior: edit the spec, then regenerate `cf-ddns.py` from scratch using only the spec as input. Do not read the existing `cf-ddns.py` while regenerating — it would contaminate the output with prior decisions.

## Files you may edit

| File                           | Editable | Notes                                 |
| ------------------------------ | -------- | ------------------------------------- |
| `cf-ddns.spec.md`              | yes      | Source of truth for the script.       |
| `tests/**`                     | yes      | Test infrastructure.                  |
| `.github/workflows/**`         | yes      | CI configuration.                     |
| `README.md`, `CONTRIBUTING.md` | yes      | Docs.                                 |
| `cf-ddns.py`                   | no       | Overwrite only via full regeneration. |

## Regeneration procedure

1. Edit `cf-ddns.spec.md` to describe the desired behavior.
2. Spawn a fresh subagent with no prior context. Give it only the spec path and the instruction: "implement `cf-ddns.py` strictly from `cf-ddns.spec.md`; do not read any existing `cf-ddns.py`."
3. The subagent writes `cf-ddns.py` from scratch.
4. Run tests: `python -m unittest -v tests.test_unit tests.test_install`.
5. If tests fail, fix the spec (not the script). Regenerate.
6. Commit spec + script + test changes together. Note the model in the commit body.

## Conventions

- Python stdlib only. No `requirements.txt`, no `pip install` in CI.
- Tests use `unittest` (not pytest) to match the script's stdlib-only ethos.
- Target Python 3.6+ (older routers in production).
- Linux-only runtime: `fcntl`, `ip`, `dig`, `systemctl` are all assumed.

## Test overrides

- `CF_DDNS_ETC_DIR` — redirects `install`/`uninstall`/`status` to a tempdir, skips `systemctl`. Used by `tests/test_install.py`. Invisible to normal users.

## Integration test secrets

Set these repo secrets for GitHub Actions to run integration tests:

- `CF_API_TOKEN` — Cloudflare API token with `Zone.DNS:Edit` on a dedicated test zone.
- `CF_ZONE_ID` — zone id.
- `CF_TEST_HOSTNAME` — a hostname inside that zone.

Never use a production token for tests.

## What an agent should not do

- Do not edit `cf-ddns.py` directly to fix a bug. Fix the spec.
- Do not add third-party dependencies.
- Do not rewrite the test suite to use pytest/fixtures/mocks — mocks are avoided on principle; real Cloudflare is the authoritative backend for integration tests.
- Do not add CLI surface not described in the spec.
