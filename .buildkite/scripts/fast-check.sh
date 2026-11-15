#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
platform="${1:-macos}"
"$root/.buildkite/scripts/runner-ready.sh" "$platform"
case "$platform:$(uname -s)" in
  macos:Darwin)
    export PATH="/opt/homebrew/bin:$PATH"
    export PATH="$(brew --prefix python@3.13)/libexec/bin:$(brew --prefix llvm@22)/bin:$(brew --prefix lld@22)/bin:$PATH"
    for node_bin in "$HOME"/.nvm/versions/node/*/bin; do
      if [ -x "$node_bin/node" ]; then
        export PATH="$node_bin:$PATH"
        break
      fi
    done
    ;;
  linux:Linux)
    export PATH="/opt/neucine-release-tools/zig-0.17.0:/usr/lib/llvm-22/bin:$PATH"
    ;;
  *) echo 'Unsupported fast-check host' >&2; exit 1 ;;
esac

zig build
.buildkite/scripts/repository-checks.sh
if [ "$platform" = linux ]; then
  test_log="$(mktemp)"
  trap 'rm -f "$test_log"' EXIT
  set +e
  zig build test-fast -j2 --summary all 2>&1 | tee "$test_log"
  test_status=${PIPESTATUS[0]}
  set -e
  if [ "$test_status" -ne 0 ]; then
    test_binary="$(awk '/^failed command: / { print $3; exit }' "$test_log")"
    if [ -n "$test_binary" ] && [ -x "$test_binary" ]; then
      echo '--- Direct test output for failed Zig test run'
      "$test_binary" || true
    fi
    exit "$test_status"
  fi
else
  zig build test-fast --summary all
fi
test "$(zig-out/bin/cyna version 2>&1)" = "cyna $(python3 .buildkite/scripts/current-version.py)"
