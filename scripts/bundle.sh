#!/usr/bin/env bash
# Builds Pointracker.app into ./build.
#
#   scripts/bundle.sh                 # native architecture, ad-hoc signed
#   UNIVERSAL=1 scripts/bundle.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Apple Development: …" scripts/bundle.sh
#
# With ad-hoc signing macOS may ask for Accessibility again after each
# rebuild; signing with a stable identity avoids that.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR=".build/apple/Products/Release"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP="build/Pointracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pointracker" "$APP/Contents/MacOS/Pointracker"
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
