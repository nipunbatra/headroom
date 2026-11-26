#!/bin/zsh
# Submit the signed, finished DMG. Apple also issues a ticket for the app inside it.
set -euo pipefail
cd "${0:A:h}"
: "${HEADROOM_NOTARY_PROFILE:?Set the name of a notarytool Keychain profile}"
codesign --verify --strict dist/Headroom.dmg
codesign --verify --deep --strict dist/Headroom.app
# A matching built app is required to produce the offline-verifiable companion ZIP.
mount=$(mktemp -d)
trap 'hdiutil detach "$mount" >/dev/null 2>&1 || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount" dist/Headroom.dmg >/dev/null
diff -qr "$mount/Headroom.app" dist/Headroom.app
hdiutil detach "$mount" >/dev/null
rmdir "$mount"
trap - EXIT
xcrun notarytool submit dist/Headroom.dmg --keychain-profile "$HEADROOM_NOTARY_PROFILE" --wait --output-format plist > dist/notary-result.plist
notary_status=$(/usr/libexec/PlistBuddy -c 'Print :status' dist/notary-result.plist)
[[ "$notary_status" == Accepted ]] || { echo "Notarization status: $notary_status" >&2; exit 1; }
xcrun stapler staple dist/Headroom.dmg
xcrun stapler validate dist/Headroom.dmg
xcrun stapler staple dist/Headroom.app
xcrun stapler validate dist/Headroom.app
ditto -c -k --keepParent dist/Headroom.app dist/.Headroom-notarized.zip
mv dist/.Headroom-notarized.zip dist/Headroom.zip
spctl --assess --type open --context context:primary-signature dist/Headroom.dmg
spctl --assess --type execute dist/Headroom.app
