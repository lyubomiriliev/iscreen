#!/bin/bash
# Builds iScreen.app (universal) and packages it as build/iScreen.dmg.
# Signing uses the local "iScreen Local Signing" certificate in ~/.iscreen-signing when present.
# A stable identity keeps the Screen Recording permission across rebuilds; ad-hoc signing ("-")
# changes on every build, so macOS would treat each build as a new, unapproved app.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iScreen"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
SIGN_KEYCHAIN="$HOME/.iscreen-signing/iscreen.keychain-db"
SIGN_ARGS=(--sign "${SIGN_ID:--}")
if [ -z "${SIGN_ID:-}" ] && [ -f "$SIGN_KEYCHAIN" ]; then
  security unlock-keychain -p "$(cat "$HOME/.iscreen-signing/keychain-password")" "$SIGN_KEYCHAIN"
  HASH=$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/iScreen Local Signing/ {print $2; exit}')
  [ -n "$HASH" ] && SIGN_ARGS=(--keychain "$SIGN_KEYCHAIN" --sign "$HASH")
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
scripts/fetch_sparkle.sh

echo "→ Compiling"
for arch in arm64 x86_64; do
  # FoundationModels (Apple's on-device AI) only exists on macOS 26+, so it is weak-linked.
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -Xlinker -weak_framework -Xlinker FoundationModels \
    -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$BUILD/$APP_NAME-$arch" Sources/*.swift
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$BUILD/$APP_NAME"

echo "→ Icon"
if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make_icon.swift "$BUILD/icon_1024.png"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$BUILD/icon_1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz * 2)) $((sz * 2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "→ Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto Vendor/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# Sign Sparkle's helpers inside-out with the same identity as the app (Sparkle ships them ad-hoc signed).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force "${SIGN_ARGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force "${SIGN_ARGS[@]}" "$SPARKLE/Autoupdate"
codesign --force "${SIGN_ARGS[@]}" "$SPARKLE/Updater.app"
codesign --force "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${SIGN_ARGS[@]}" --identifier com.iscreen.app "$APP"
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

echo "→ DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ $BUILD/$APP_NAME.dmg"
