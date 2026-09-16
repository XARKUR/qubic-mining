#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTPUT_DIR="${2:-$ROOT_DIR/dist}"

if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
  echo "Usage: $0 <version, e.g. 1.0.0> [output-dir]" >&2
  exit 2
fi
VERSION="${VERSION#v}"

required_files=(
  LICENSE
  README.md
  README.zh-CN.md
  CHANGELOG.md
  miner-install.sh
  scripts/package-release.sh
  tests/fixtures/curl
  tests/miner-install-tests.sh
  tests/miner-install-integration.sh
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$ROOT_DIR/$path" || -L "$ROOT_DIR/$path" ]]; then
    echo "Required release file is missing or is a symlink: $path" >&2
    exit 1
  fi
done

for script in miner-install.sh scripts/package-release.sh tests/fixtures/curl tests/miner-install-tests.sh tests/miner-install-integration.sh; do
  bash -n "$ROOT_DIR/$script"
done
"$ROOT_DIR/tests/miner-install-tests.sh"
"$ROOT_DIR/tests/miner-install-integration.sh"

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
package_name="qubic-miner-installer-$VERSION"
package_dir="$stage/$package_name"

for path in "${required_files[@]}"; do
  install -D -m 0644 -- "$ROOT_DIR/$path" "$package_dir/$path"
done
chmod 0755 "$package_dir/miner-install.sh" "$package_dir/scripts/package-release.sh" "$package_dir/tests/fixtures/curl" "$package_dir/tests/miner-install-tests.sh" "$package_dir/tests/miner-install-integration.sh"

sums_tmp="$stage/SOURCE-SHA256SUMS"
(
  cd "$package_dir"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$sums_tmp"
mv -- "$sums_tmp" "$package_dir/SOURCE-SHA256SUMS"

mkdir -p -- "$OUTPUT_DIR"
archive="$OUTPUT_DIR/$package_name.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-0}" -czf "$archive" -C "$stage" "$package_name"
(
  cd "$OUTPUT_DIR"
  sha256sum "$package_name.tar.gz" > "$package_name.tar.gz.sha256"
  sha256sum -c "$package_name.tar.gz.sha256" >/dev/null
)

echo "Created: $archive"
echo "Checksum: $archive.sha256"
