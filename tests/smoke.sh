#!/usr/bin/env bash
# A read-only check of a running container; nothing generic knows these
# parts.
# Smoke test for a running container (either image). Read-only: it checks what can
# be observed and says plainly what it cannot prove.
#   tests/smoke.sh [service]
# Exit 0 only when every check that can pass today passes.
set -euo pipefail

svc=${1:-sn2}
cd "$(dirname "$0")/.."
fail=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check()
inside() { docker compose exec -T "$svc" "$@"; }

check "container running" sh -c "docker compose ps --status running --services | grep -qx '$svc'"
check "healthcheck script passes" inside /opt/sn2/bin/healthcheck.sh
# shellcheck disable=SC2016  # the variables expand inside the container
check "control dir is private" inside sh -c '[ "$(stat -c %a "$SN2_CONTROL_DIR")" = 700 ]'
# shellcheck disable=SC2016
check "Wine prefix exists" inside sh -c '[ -d "$DATA_DIR/wine/drive_c" ]'
check "no Steam library bind mount" sh -c \
  "! docker inspect \$(docker compose ps -q '$svc') --format '{{range .Mounts}}{{.Type}} {{end}}' | grep -qw bind"

echo
echo "Not checked here (needs a signed-in account and a second player):"
echo "  - the game reaches readiness under -nullrhi (moonpool status)"
echo "  - HostSessionAsync succeeds and a second account can discover and join"
exit "$fail"
