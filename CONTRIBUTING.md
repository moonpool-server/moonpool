# Contributing

Issues and pull requests are welcome. One person maintains this in spare time: expect days, not hours.

## What you need to run the tests

| Tool | For |
|---|---|
| [uv](https://docs.astral.sh/uv/) | `uvx pre-commit`, and the Python test hooks (they fetch their own packages) |
| Docker | the bats suite, hadolint and actionlint (each runs in a container) |
| `luacheck` on PATH | the Lua lint (Ubuntu: `lua-check`) |
| Python 3 | the repo policy check |
| Windows PowerShell 5.1 | the launcher tests (Windows only) |

## Before you open a pull request

- Run `uvx pre-commit run --all-files`: shellcheck, hadolint, luacheck, yamllint, the Python tests and the bats suite. CI also scans history for secrets, builds and scans the image, and runs the launcher tests on Windows.
- One suite on its own:

  | Suite | Command |
  |---|---|
  | one Lua spec | `lua5.4 tests/lua/json_spec.lua` (any file in `tests/lua/`, run from the repo root) |
  | launcher | `powershell -NoProfile -ExecutionPolicy Bypass -File client/tests/moonpool.tests.ps1`, with no Moonpool launcher of yours running (one launcher per Windows user) |
  | one Python test | `uv run --no-project --with pytest python -m pytest -q tests/test_tick_report.py` |
- One change per pull request. A fix and a tidy-up are two.
- Say how you tested it: a host that came up, a player that joined, a test that failed before and passes now.
- Never commit game files, Steam sessions, Wine prefixes, logs, saves or anything the game generated. The hooks refuse some by name or extension (saves, paks, game binaries, layout files, Steam login files), not all; check what you add.

## How a change lands

Every change goes through a pull request. CI must pass and main only moves forward. The maintainer squash-merges, one commit per change. Release tags are protected and releases are immutable.

## What goes where

- `docker/` and `scripts/`: run inside the container. Shell for process and file work, Python where a library does it better.
- `mod/`: the UE4SS Lua mod that runs in the game on the host.
- `client/`: the player launcher, in PowerShell, which every Windows PC has.
- `bin/moonpool`: the admin command, Python with no packages to install; it talks to the container.
- `tests/`: bats for shell, `tests/lua` for the mod, `test_*.py` for Python.

## Security problems

Not in an issue. Use [private reporting](https://github.com/moonpool-server/moonpool/security/advisories/new) as [SECURITY.md](SECURITY.md) says.
