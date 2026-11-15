#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
platform="${1:?platform required}"
stage="${2:-all}"
version="$(buildkite-agent meta-data get release_version)"
mode="$(buildkite-agent meta-data get release_mode)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || exit 1
[[ "$mode" == full || "$mode" == preflight ]] || exit 1
export VERSION="$version" RUNNER_TEMP="$(mktemp -d)"
trap 'rm -rf "$RUNNER_TEMP"' EXIT

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
    export CYNA_RELEASE_ZIG_JOBS=2
    ;;
  *) echo "Wrong host for $platform" >&2; exit 1 ;;
esac

prepare_dependencies() {
"$root/.buildkite/scripts/runner-ready.sh" "$platform" "$version"
}

prepare_tools() {
  test -d .zig-cache || { echo 'Runner readiness must precede build' >&2; exit 1; }
}

build_binary() {
  [ "$mode" = full ] || return 0
  echo "--- Build binary"
  zig build -Doptimize=fast
  # Zig may reuse a content-identical cached archive whose old mtime predates
  # this checkout. A successful build validates the current C inputs.
  touch zig-out/lib/libcyna.a zig-out/lib/libcyna_std.a
  test "$(zig-out/bin/cyna version 2>&1)" = "cyna $version"
  if [ "$platform" = macos ]; then
    .buildkite/scripts/repository-checks.sh
  fi
}

package_distribution() {
  [ "$mode" = full ] || return 0
  echo "--- Package distribution"
  python3 scripts/release_distribution.py plan --release-version "$version"
  verify_args=(--no-cava --prebuilt-binary)
  if [[ "${BUILDKITE_STEP_KEY:-}" == final-macos || "${BUILDKITE_STEP_KEY:-}" == final-linux ]]; then
    verify_args+=(--reuse-candidate-tests)
  fi
  python3 scripts/release_distribution.py verify "${verify_args[@]}"
  buildkite-agent artifact upload "dist/distributions/$version/*.tar.gz"
  buildkite-agent artifact upload 'dist/release/state/*.json'
}

case "$stage" in
  dependencies) prepare_dependencies ;;
  tools) prepare_tools ;;
  build) build_binary ;;
  package) package_distribution ;;
  all)
    prepare_dependencies
    prepare_tools
    build_binary
    package_distribution
    ;;
  *) echo "Unknown release stage: $stage" >&2; exit 1 ;;
esac
