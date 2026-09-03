#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/.build/tests"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR/module-cache"
xcrun swiftc \
  -DTESTING \
  -target "$ARCH-apple-macos14.0" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT_DIR/Sources/AIUsageDesklet.swift" \
  "$ROOT_DIR/Tests/main.swift" \
  -o "$BUILD_DIR/rate-limit-tests"

"$BUILD_DIR/rate-limit-tests"
