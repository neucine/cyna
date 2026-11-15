#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo '--- Check compiler tooling'
python3 -m unittest discover -s scripts -p 'test_*.py'

echo '--- Check native task groups'
cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -pthread -I. -Isrc/runtime \
  test/runtime/task_group_native.c packages/std/src/std_task_group.c \
  src/runtime/failure_trace.c -o "$tmp/cyna-task-group-native-test"
"$tmp/cyna-task-group-native-test"

echo '--- Check site content'
python3 scripts/prepare_site_content.py --check

echo '--- Check formatting'
./scripts/format.sh --check
zig fmt --check build.zig src test
