#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Codex计费"
EXECUTABLE_NAME="AIUsageDesklet"
DIST_ZIP="$DIST_DIR/$APP_NAME.app.zip"
LEGACY_DIST_APP="$DIST_DIR/AIUsageDesklet.app"
LEGACY_DIST_ZIP="$DIST_DIR/AIUsageDesklet.app.zip"
WIDGET_NAME="AIUsageDeskletWidget"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos14.0"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-desklet.XXXXXX")"
STAGED_APP="$STAGE_ROOT/$APP_NAME.app"
WIDGET_BUNDLE="$STAGED_APP/Contents/PlugIns/$WIDGET_NAME.appex"
trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$BUILD_DIR/module-cache" "$STAGED_APP/Contents/MacOS" "$WIDGET_BUNDLE/Contents/MacOS"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT_DIR/Widget/AIUsageDeskletWidget.swift" \
  -o "$WIDGET_BUNDLE/Contents/MacOS/$WIDGET_NAME"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT_DIR/Sources/AIUsageDesklet.swift" \
  -o "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"

cp "$ROOT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT_DIR/Widget/Info.plist" "$WIDGET_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Widget/Widget.entitlements" "$BUILD_DIR/Widget.entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.temporary-exception.files.absolute-path.read-only:0 $HOME/Library/Application Support/AIUsageDesklet/" \
  "$BUILD_DIR/Widget.entitlements"

xattr -cr "$STAGED_APP"
codesign --force --sign - --entitlements "$BUILD_DIR/Widget.entitlements" "$WIDGET_BUNDLE"
codesign --force --sign - --entitlements "$ROOT_DIR/App.entitlements" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$DIST_DIR"
rm -rf "$LEGACY_DIST_APP"
rm -f "$LEGACY_DIST_ZIP"
rm -f "$DIST_ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$DIST_ZIP"

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
  LEGACY_INSTALL_PATH="$INSTALL_DIR/AIUsageDesklet.app"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$LEGACY_INSTALL_PATH"
  rm -rf "$INSTALL_PATH"
  ditto --norsrc --noextattr "$STAGED_APP" "$INSTALL_PATH"
  codesign --verify --deep --strict "$INSTALL_PATH"
  open "$INSTALL_PATH"
  echo "已安装并打开：$INSTALL_PATH"
else
  echo "构建完成：$DIST_ZIP"
fi
