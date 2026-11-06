# Contributing

Issues and pull requests are welcome. One person maintains this in spare time so expect days not hours

## Before you open a pull request

- Run `pre-commit run --all-files`. It runs the same checks as CI: shellcheck, hadolint, luacheck, yamllint, the Python tests and the bats suite
- Keep it to one change. A fix and a tidy up are two pull requests
- Say how you tested it. A host that came up, a player that joined, a test that failed before and passes now
- Never commit game files, Steam sessions, Wine prefixes, logs, saves or anything the game generated. The pre-commit hooks refuse the obvious ones but you are the real check

## How a change lands

Every change goes through a pull request, CI has to pass and main only moves forward. The maintainer merges with squash or rebase so history stays one line per change. Release tags are protected and releases are immutable

## What goes where

- `docker/` and `scripts/` run inside the container. Shell for process and file work, Python where a library earns its keep
- `mod/` is the UE4SS Lua mod that runs inside the game on the host
- `client/` is the player launcher, PowerShell because that is what every Windows PC has
- `bin/moonpool` is the admin command, shell, talks to the container
- `tests/` holds bats for shell, `tests/lua` for the mod and `test_*.py` for the Python

## Security problems

Not in an issue. Use [private reporting](https://github.com/moonpool-server/moonpool/security/advisories/new) as [SECURITY.md](SECURITY.md) says
