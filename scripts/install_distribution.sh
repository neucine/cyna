#!/usr/bin/env sh
set -eu

# Update this on each release so the bootstrap script installs the current
# public distribution by default.
CYNA_RELEASE_VERSION="${CYNA_RELEASE_VERSION:-0.5.4}"

usage() {
    cat <<'EOF'
usage: install_distribution.sh [version] [host]

Installs a released Cyna host distribution under:
  ~/.cyna/<version>/
and updates:
  ~/.cyna/current -> ~/.cyna/<version>
  ~/.cyna/bin/cyna -> ~/.cyna/current/bin/cyna  (convenience link)

Examples:
  curl -fsSL https://cyna.dev/install.sh | sh
  curl -fsSL https://cyna.dev/install.sh | sh -s -- 0.5.4
  curl -fsSL https://cyna.dev/install.sh | sh -s -- 0.5.4 aarch64-apple-darwin

Environment overrides:
  CYNA_RELEASE_VERSION        default bundled release version
  CYNA_DISTRIBUTION_BASE_URL  default: https://downloads.cyna.dev/distributions
  CYNA_DISTRIBUTION_URL       exact archive URL to download
  CYNA_INSTALL_ROOT           default: $HOME/.cyna
EOF
}

detect_host() {
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os:$arch" in
        Darwin:arm64) echo "aarch64-apple-darwin" ;;
        Darwin:x86_64) echo "x86_64-apple-darwin" ;;
        Linux:x86_64) echo "x86_64-unknown-linux-gnu" ;;
        *)
            echo "unsupported host: $os $arch" >&2
            exit 1
            ;;
    esac
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -gt 2 ]; then
    usage >&2
    exit 1
fi

version="${1:-$CYNA_RELEASE_VERSION}"
host="${2:-$(detect_host)}"
base_url="${CYNA_DISTRIBUTION_BASE_URL:-https://downloads.cyna.dev/distributions}"
archive_url="${CYNA_DISTRIBUTION_URL:-${base_url}/${version}/${host}.tar.gz?v=${version}}"
install_root="${CYNA_INSTALL_ROOT:-$HOME/.cyna}"
dest_dir="${install_root}/${version}"
current_link="${install_root}/current"
bin_dir="${install_root}/bin"
cyna_link="${bin_dir}/cyna"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cyna-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

archive_path="${tmp_dir}/distribution.tar.gz"
extract_dir="${tmp_dir}/extract"
mkdir -p "$extract_dir"

echo "installing Cyna ${version} for ${host}"
echo "downloading ${archive_url}"
curl -fsSL "$archive_url" -o "$archive_path"
tar -xzf "$archive_path" -C "$extract_dir"

payload_root="$extract_dir"
if [ -d "${extract_dir}/${host}" ]; then
    payload_root="${extract_dir}/${host}"
elif [ -d "${extract_dir}/${version}" ]; then
    payload_root="${extract_dir}/${version}"
elif [ -d "${extract_dir}/distribution" ]; then
    payload_root="${extract_dir}/distribution"
fi

mkdir -p "$dest_dir"
rm -rf "${dest_dir:?}/"*
cp -R "$payload_root"/. "$dest_dir"/
ln -sfn "$dest_dir" "$current_link"
mkdir -p "$bin_dir"
ln -sfn "${current_link}/bin/cyna" "$cyna_link"

cat <<EOF
installed Cyna ${version} at ${dest_dir}
updated symlinks:
  ${current_link}
  ${cyna_link}

binary:
  ${dest_dir}/bin/cyna

add to PATH once:
  export PATH="${install_root}/current/bin:\$PATH"
EOF
