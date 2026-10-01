#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

test_state="$(mktemp -d)"
trap 'rm -rf "$test_state"' EXIT

for file in tests/*.lua; do
  case "$file" in
    tests/live_*|tests/direct_http.lua|tests/direct_pair_flow.lua|tests/install_smoke.lua) continue ;;
  esac
  echo "==> $file"
  XDG_STATE_HOME="$test_state/$(basename "$file" .lua)" nvim --headless -u NONE -l "$file"
done

echo "==> direct API loopback HTTP and editor flow"
XDG_STATE_HOME="$test_state/http" python3 tests/run_direct_http.py
