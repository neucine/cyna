#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
platform="${1:?platform required}"
version="${2:-}"
if [ "$version" = --from-buildkite ]; then
  version="$(buildkite-agent meta-data get release_version)"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
  *) echo "Wrong host for $platform" >&2; exit 1 ;;
esac

echo '--- Check pinned runner tools and dependencies'
python3 - "$version" <<'PY'
import pathlib, re, sys
assert sys.version_info >= (3, 13), "Python 3.13 or newer is required"
version = sys.argv[1]
if version:
    build = pathlib.Path('build.zig').read_text()
    versions = set(re.findall(r'"(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"', build))
    assert version in versions, f"build.zig versions {versions} do not include {version}"
    install = pathlib.Path('scripts/install_distribution.sh').read_text()
    match = re.search(r'CYNA_RELEASE_VERSION="\$\{CYNA_RELEASE_VERSION:-([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)\}"', install)
    assert match and match.group(1) == version, "installer version does not match release version"
PY
test "$(zig version)" = 0.17.0
test "$(basename "$(clang -print-resource-dir)")" = 22
for tool in python3 zig clang llvm-ar llvm-objcopy ld.lld node cc ar; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done

: "${PRIVATE_REPO_READ_TOKEN:?PRIVATE_REPO_READ_TOKEN is required}"
askpass="$tmp/askpass"
cat > "$askpass" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *) printf '%s\n' "$PRIVATE_REPO_READ_TOKEN" ;;
esac
EOF
chmod 700 "$askpass"
export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0
libs="$root/../zig-libs"
if [ ! -d "$libs/.git" ]; then
  git -c credential.helper= clone --quiet https://github.com/neucine/zig-libs.git "$libs"
  git -C "$libs" config cyna.buildkiteManaged true
fi
case "$(git -C "$libs" remote get-url origin)" in
  https://github.com/neucine/zig-libs.git|git@github.com:neucine/zig-libs.git) ;;
  *) echo 'Unexpected zig-libs origin' >&2; exit 1 ;;
esac
if [ "$(git -C "$libs" rev-parse HEAD)" != a91b58271be94a4e402a856403fe0fa83add1709 ]; then
  if [ "$(git -C "$libs" config --get cyna.buildkiteManaged || true)" != true ]; then
    echo "Existing zig-libs checkout is not managed by Buildkite and is at another commit: $libs" >&2
    exit 1
  fi
  test -z "$(git -C "$libs" status --porcelain)" || { echo 'Managed zig-libs checkout is dirty' >&2; exit 1; }
  if ! git -C "$libs" cat-file -e a91b58271be94a4e402a856403fe0fa83add1709^{commit} 2>/dev/null; then
    git -C "$libs" -c credential.helper= fetch --quiet origin a91b58271be94a4e402a856403fe0fa83add1709
  fi
  git -C "$libs" checkout --quiet --detach a91b58271be94a4e402a856403fe0fa83add1709
fi
test "$(git -C "$libs" rev-parse HEAD)" = a91b58271be94a4e402a856403fe0fa83add1709
unset PRIVATE_REPO_READ_TOKEN GIT_ASKPASS GIT_TERMINAL_PROMPT

cache="$HOME/.cache/neucine/cyna-zig-0.17.0"
mkdir -p "$cache"
if [ -e .zig-cache ] && [ ! -d .zig-cache ]; then
  echo '.zig-cache must be a directory or symlink to the runner cache' >&2
  exit 1
fi
if [ ! -e .zig-cache ]; then
  ln -s "$cache" .zig-cache
fi
exclude="$(git rev-parse --git-path info/exclude)"
if ! grep -Fxq '.zig-cache' "$exclude" 2>/dev/null; then
  printf '%s\n' .zig-cache >> "$exclude"
fi

if [ -n "$version" ]; then
  "$root/.buildkite/scripts/bootstrap-compiler-rt-$platform.sh"
  clang -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -pthread -I. -Isrc/runtime \
    test/runtime/task_group_native.c packages/std/src/std_task_group.c \
    src/runtime/failure_trace.c -o "$tmp/cyna-task-group-native-test"
  "$tmp/cyna-task-group-native-test"
fi
echo "runner ready: $platform${version:+ for $version}"
