#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cyna_bin=${CYNA_BIN:-"$root/zig-out/bin/cyna"}

if [ ! -x "$cyna_bin" ]; then
    echo "Cyna formatter not found at $cyna_bin; run 'zig build' first." >&2
    exit 2
fi

exec "$cyna_bin" fmt \
    "$root/examples" \
    "$root/packages/std" \
    "$root/packages/embedded/src/arch" \
    "$root/packages/embedded/src/hal" \
    "$root/tools/cyna-vscode/samples" \
    "$@"
