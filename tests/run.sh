#!/usr/bin/env bash
# Runs the Lua specs against an isolated data directory, so a spec can never
# touch the connections or UI state of the machine it runs on.
set -uo pipefail
cd "$(dirname "$0")/.."

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export XDG_DATA_HOME="$sandbox/data"
export XDG_STATE_HOME="$sandbox/state"
export XDG_CACHE_HOME="$sandbox/cache"

failed=0
for spec in tests/lua/*_spec.lua; do
  printf '%-26s ' "$(basename "$spec")"
  if output=$(nvim -u NONE -l "$spec" 2>&1); then
    echo "PASS"
  else
    echo "FAIL"
    echo "$output" | sed 's/^/    /'
    failed=1
  fi
done
exit $failed
