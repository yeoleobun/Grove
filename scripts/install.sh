#!/bin/zsh
set -euo pipefail

REPO="yeoleobun/Grove"
ASSET="Grove-macos-arm64.zip"
INSTALL_DIR="/Applications"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Error: Grove requires macOS on Apple Silicon (arm64)." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Downloading latest ${ASSET} from ${REPO}..."
curl -fsSL "https://github.com/${REPO}/releases/latest/download/${ASSET}" -o "${TMP_DIR}/${ASSET}"

echo "==> Extracting Grove.app..."
ditto -x -k "${TMP_DIR}/${ASSET}" "${TMP_DIR}"

pkill -x Grove 2>/dev/null || true
rm -rf "${INSTALL_DIR}/Grove.app"
mv "${TMP_DIR}/Grove.app" "${INSTALL_DIR}/Grove.app"
xattr -cr "${INSTALL_DIR}/Grove.app"

echo "==> Installed to ${INSTALL_DIR}/Grove.app! Launching Grove..."
open "${INSTALL_DIR}/Grove.app"
