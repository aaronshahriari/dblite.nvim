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

# Window sizing cannot be tested with `nvim -l`: the layout never reflows there
# and nvim_ui_attach is unavailable, so a spec that measures a window measures
# an 80-column grid whatever it set. These run in a pty of a known size, each in
# its own nvim so a deliberate resize cannot leak into the next case.
if command -v python3 > /dev/null; then
  for spec in tests/window/*_spec.lua; do
    [ -e "$spec" ] || continue
    printf '%-26s ' "$(basename "$spec" .lua)@pty"
    if output=$(python3 tests/run_in_pty.py 200 50 "$spec" "$sandbox/window-$(basename "$spec" .lua)" 2>&1); then
      echo "PASS"
    else
      echo "FAIL"
      echo "$output"
      failed=1
    fi
  done
else
  echo "python3 missing — skipping the pty window specs"
fi

exit $failed
