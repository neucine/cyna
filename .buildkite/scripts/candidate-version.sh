#!/usr/bin/env bash
set -euo pipefail

case "${BUILDKITE_BRANCH:?}" in
  release/v*) version="${BUILDKITE_BRANCH#release/v}" ;;
  *) echo 'Expected a release/v branch' >&2; exit 1 ;;
esac
declared="$(python3 .buildkite/scripts/current-version.py)"
test "$declared" = "$version" || {
  echo "Release branch version $version differs from declared version $declared" >&2
  exit 1
}
buildkite-agent meta-data set release_version "$version"
buildkite-agent meta-data set release_mode full
