# Contributing to b2f

We welcome contributions to the Back to the Future (`b2f`) engine!

## Development Guidelines

1. **Zero Third-Party Dependencies**: The core Python engine (`scripts/b2f_engine.py`) must remain pure Python standard library compatible with Python >= 3.8.
2. **Defensive Shelling**: All shell code must run with `set -euo pipefail` and pass `bash -n`.
3. **Automated Testing**: Any new subcommand or bug fix must be covered by an automated test case in `tests/test_b2f_engine.py`.
4. **Zero Path Leakage**: Never hardcode personal paths or usernames (`/Users/...`, `/home/...`).

## Running Tests Locally

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/b2f_helper.sh
bash -n setup.sh
```
