#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Grove"
BINARY_TARGET="Grove"
VERSION="${VERSION:-0.1.0}"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-macos-arm64.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}-macos-arm64.dmg"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Compiling ${APP_NAME} ${VERSION} (release, arm64)..."
cd "${ROOT_DIR}"
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/${BINARY_TARGET}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Error: compiled binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Preparing ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}" "${ZIP_PATH}" "${DMG_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> Generating app icon..."
TMP_ICON_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_ICON_DIR}"' EXIT
ICONSET_DIR="${TMP_ICON_DIR}/AppIcon.iconset"
swift "${ROOT_DIR}/scripts/generate_icon.swift" "${ICONSET_DIR}"

ICON_HASH="$(cat "${ROOT_DIR}/scripts/generate_icon.swift" "${ROOT_DIR}/Resources/AppIconArtwork.jpg" | shasum -a 256 | cut -c1-8)"
ICON_NAME="AppIcon-${ICON_HASH}"
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/${ICON_NAME}.icns"

echo "==> Writing Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>dev.grove.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Creating ${ZIP_PATH}..."
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

if [[ "${PACKAGE_DMG:-0}" == "1" ]]; then
    echo "==> Creating ${DMG_PATH}..."
    STAGING_DIR="$(mktemp -d)"
    cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
    ln -s /Applications "${STAGING_DIR}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}" >/dev/null
    rm -rf "${STAGING_DIR}"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi
touch "${APP_BUNDLE}"

echo "==> Done! App bundle created at: ${APP_BUNDLE} (v${VERSION})"
