#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="AIUsageDesklet"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
WIDGET_NAME="AIUsageDeskletWidget"
WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$WIDGET_NAME.appex"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos14.0"

rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR/module-cache" "$APP_BUNDLE/Contents/MacOS" "$WIDGET_BUNDLE/Contents/MacOS"

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
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Widget/Info.plist" "$WIDGET_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Widget/Widget.entitlements" "$BUILD_DIR/Widget.entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.temporary-exception.files.absolute-path.read-only:0 $HOME/Library/Application Support/AIUsageDesklet/" \
  "$BUILD_DIR/Widget.entitlements"

xattr -cr "$APP_BUNDLE"
codesign --force --sign - --entitlements "$BUILD_DIR/Widget.entitlements" "$WIDGET_BUNDLE"
codesign --force --sign - --entitlements "$ROOT_DIR/App.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_PATH"
  ditto "$APP_BUNDLE" "$INSTALL_PATH"
  open "$INSTALL_PATH"
  echo "已安装并打开：$INSTALL_PATH"
else
  echo "构建完成：$APP_BUNDLE"
fi
