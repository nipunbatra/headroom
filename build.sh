#!/bin/zsh
# Builds dist/Headroom.app: the native SwiftUI app with its Swift scanner, self-contained.
# Needs the Xcode Command Line Tools (swiftc). No Xcode project.
#   ./build.sh            build the app, drag-to-Applications DMG and ZIP (universal, optimised)
#   ./build.sh --debug    quick build for this Mac only, no zip
#   ./build.sh --install  also move the app into /Applications and open it
set -euo pipefail
cd "${0:A:h}"
# Expose the SDK’s descriptor-relative recursive removal API to Swift.
REMOVEFILE_HEADER="$(xcrun --sdk macosx --show-sdk-path)/usr/include/removefile.h"
mkdir -p dist
T=$(mktemp -d dist/.headroom-build.XXXXXXXX)
trap 'rm -rf "$T"' EXIT
APP="$T/Headroom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/Headroom"
SRC=(app/Engine/*.swift app/Sources/*.swift)
if [[ " $* " == *" --debug "* ]]; then
  swiftc -Onone -import-objc-header "$REMOVEFILE_HEADER" -parse-as-library -target "$(uname -m)-apple-macos14.0" -o "$BIN" $SRC
else
  # Universal binary (Apple silicon + Intel) so the app can be shared.
  swiftc -O -import-objc-header "$REMOVEFILE_HEADER" -parse-as-library -target arm64-apple-macos14.0 -o "$T/arm64" $SRC
  swiftc -O -import-objc-header "$REMOVEFILE_HEADER" -parse-as-library -target x86_64-apple-macos14.0 -o "$T/x86_64" $SRC
  lipo -create "$T/arm64" "$T/x86_64" -output "$BIN"
fi
cp app/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f app/AppIcon.icns ]]; then
  TMP="$T/icon"; SET=$TMP/AppIcon.iconset; mkdir -p "$SET"
  swiftc -o "$TMP/make_icon" app/make_icon.swift -framework Cocoa
  "$TMP/make_icon" "$SET/base.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SET/base.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SET/base.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm "$SET/base.png"
  iconutil -c icns "$SET" -o app/AppIcon.icns
fi
cp app/AppIcon.icns "$APP/Contents/Resources/"
if [[ -n "${HEADROOM_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
if [[ " $* " != *" --debug "* ]]; then
  ditto -c -k --keepParent "$APP" "$T/Headroom.zip"
  mkdir "$T/image"
  ditto "$APP" "$T/image/Headroom.app"
  ln -s /Applications "$T/image/Applications"
  hdiutil create -quiet -volname Headroom -fs HFS+ -srcfolder "$T/image" -format UDZO "$T/Headroom.dmg"
  if [[ -n "${HEADROOM_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --identifier local.headroom.installer --sign "$HEADROOM_SIGN_IDENTITY" "$T/Headroom.dmg"
    codesign --verify --strict "$T/Headroom.dmg"
  fi
  mv -f "$T/Headroom.dmg" dist/Headroom.dmg
  mv -f "$T/Headroom.zip" dist/Headroom.zip
fi
if [[ -e dist/Headroom.app ]]; then mv dist/Headroom.app "$T/previous.app"; fi
mv "$APP" dist/Headroom.app
APP=dist/Headroom.app
if [[ " $* " == *" --debug "* ]]; then
  echo "Built $APP (debug)."
  exit 0
fi
if [[ " $* " == *" --install "* ]]; then
  osascript -e 'quit app "Headroom"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Headroom.app
  ditto "$APP" /Applications/Headroom.app
  echo "Installed /Applications/Headroom.app (disk image for sharing: dist/Headroom.dmg)"
else
  echo "Built $APP, dist/Headroom.dmg and dist/Headroom.zip. Run ./build.sh --install to put it in Applications."
fi
