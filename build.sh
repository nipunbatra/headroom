#!/bin/zsh
# Builds dist/Headroom.app: a native window plus the scanner and UI, self-contained.
# Needs the Xcode Command Line Tools (swiftc).
#   ./build.sh            build dist/Headroom.app and dist/Headroom.zip
#   ./build.sh --install  also move the app into /Applications
set -euo pipefail
cd "${0:A:h}"
APP=dist/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal binary (Apple silicon + Intel) so the app can be shared; falls back to this Mac's arch.
BIN="$APP/Contents/MacOS/Headroom"; T=$(mktemp -d)
if swiftc -O -target arm64-apple-macos12 -o "$T/arm64" app/main.swift -framework Cocoa -framework WebKit 2>/dev/null \
   && swiftc -O -target x86_64-apple-macos12 -o "$T/x86_64" app/main.swift -framework Cocoa -framework WebKit 2>/dev/null; then
  lipo -create "$T/arm64" "$T/x86_64" -output "$BIN"
else
  swiftc -O -o "$BIN" app/main.swift -framework Cocoa -framework WebKit
fi
cp app/Info.plist "$APP/Contents/Info.plist"
cp scan.py index.html "$APP/Contents/Resources/"
if [[ ! -f app/AppIcon.icns ]]; then
  TMP=$(mktemp -d); SET=$TMP/AppIcon.iconset; mkdir -p "$SET"
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
codesign --force --sign - "$APP" >/dev/null 2>&1
# A zip that keeps the signature and icon, for sending to someone else.
ditto -c -k --keepParent "$APP" dist/Headroom.zip
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Headroom"' >/dev/null 2>&1 || true
  rm -rf /Applications/Headroom.app
  ditto "$APP" /Applications/Headroom.app && rm -rf "$APP"
  echo "Installed /Applications/Headroom.app (zip for sharing: dist/Headroom.zip)"
else
  echo "Built $APP and dist/Headroom.zip. Run ./build.sh --install to put it in Applications."
fi
