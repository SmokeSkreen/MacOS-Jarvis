#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Jarvis.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
MODULE_CACHE_HASH="$(printf "%s" "$ROOT" | shasum -a 256 | awk '{print $1}')"
MODULE_CACHE="$ROOT/.build/module-cache-$MODULE_CACHE_HASH"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MACOS" "$RESOURCES" "$MODULE_CACHE"

xcrun --sdk macosx swiftc \
  -O \
  -parse-as-library \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/Jarvis/main.swift" \
  -o "$MACOS/Jarvis" \
  -framework AppKit \
  -framework SwiftUI

cp "$ROOT/JarvisApp/Info.plist" "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"
chmod +x "$MACOS/Jarvis"

xattr -cr "$APP" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
