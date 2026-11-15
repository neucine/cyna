#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export PATH="$(brew --prefix python@3.13)/libexec/bin:$PATH"
for node_bin in "$HOME"/.nvm/versions/node/*/bin; do
  if [ -x "$node_bin/node" ]; then
    export PATH="$node_bin:$PATH"
    break
  fi
done
for tool in python3 node gh aws; do
  command -v "$tool" >/dev/null || { echo "Missing publication tool: $tool" >&2; exit 1; }
done

export GH_TOKEN="${GITHUB_RELEASE_TOKEN:?GITHUB_RELEASE_TOKEN is required}"
export CYNA_R2_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
export CYNA_R2_BUCKET="cyna-downloads"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

python3 .buildkite/scripts/publish-release.py
