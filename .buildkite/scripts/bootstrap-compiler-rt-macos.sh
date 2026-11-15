#!/usr/bin/env bash
set -euo pipefail

bundle="$(python3 -c 'import re, pathlib; print(re.search(r"\.id = \"llvm\",\s*\.version = \"([^\"]+)\"", pathlib.Path("src/build/model.zig").read_text(), re.S).group(1))')"
dest="dist/compiler-rt/llvm-$bundle"
if ls "$dest"/lib/clang/*/lib/riscv64-unknown-none-elf/libclang_rt.builtins.a >/dev/null 2>&1; then
  echo "compiler-rt already present: $dest"
  exit 0
fi
tmp="$(mktemp -d)"
url="https://downloads.cyna.dev/distributions/0.5.1-beta.1/aarch64-apple-darwin.tar.gz"
curl --fail --location --retry 3 --silent --show-error "$url" -o "$tmp/dist.tar.gz"
tar -xzf "$tmp/dist.tar.gz" -C "$tmp"
mkdir -p "$dest/lib"
cp -R "$tmp/aarch64-apple-darwin/llvm/lib/clang" "$dest/lib/"
echo "bootstrapped compiler-rt: $dest"
