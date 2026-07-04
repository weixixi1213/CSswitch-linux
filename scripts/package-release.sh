#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  if git -C "$REPO_ROOT" describe --tags --exact-match >/dev/null 2>&1; then
    VERSION="$(git -C "$REPO_ROOT" describe --tags --exact-match)"
  else
    VERSION="dev-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  fi
fi

PREFIX="csswitch-linux-${VERSION}"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

git -C "$REPO_ROOT" archive \
  --format=tar.gz \
  --prefix="${PREFIX}/" \
  -o "$DIST_DIR/${PREFIX}.tar.gz" \
  HEAD

git -C "$REPO_ROOT" archive \
  --format=zip \
  --prefix="${PREFIX}/" \
  -o "$DIST_DIR/${PREFIX}.zip" \
  HEAD

(
  cd "$DIST_DIR"
  sha256sum "${PREFIX}.tar.gz" "${PREFIX}.zip" > "${PREFIX}.sha256"
)

echo "Release artifacts:"
echo "  $DIST_DIR/${PREFIX}.tar.gz"
echo "  $DIST_DIR/${PREFIX}.zip"
echo "  $DIST_DIR/${PREFIX}.sha256"
