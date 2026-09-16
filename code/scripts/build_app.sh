#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
CODE_DIR="${SCRIPT_DIR:h}"
PROJECT_DIR="${CODE_DIR:h}"
BUILD_ROOT="${PROJECT_DIR}/tmp/build"
APP_DIR="${BUILD_ROOT}/Duo Privacy Demo.app"
CONTENTS_DIR="${APP_DIR}/Contents"

swift build --package-path "$CODE_DIR" -c release

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$CODE_DIR/.build/release/DuoPrivacyDemo" "$CONTENTS_DIR/MacOS/DuoPrivacyDemo"
cp "$CODE_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
