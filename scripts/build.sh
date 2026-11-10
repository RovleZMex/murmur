#!/bin/zsh
# Build Murmur.app.
#
#   scripts/build.sh            Debug-ish local build in build/Murmur.app
#   scripts/build.sh --install  Build, copy to ~/Applications and launch
#   scripts/build.sh --release  Universal build, Developer ID signed, notarized .dmg in dist/
#
# Release prerequisites (one time):
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notary credentials stored in the keychain:
#      xcrun notarytool store-credentials murmur-notary --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP=build/Murmur.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
NOTARY_PROFILE="${NOTARY_PROFILE:-murmur-notary}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

compile() { # $1 = arch
  swiftc -O -swift-version 5 -target "$1-apple-macos26.0" -parse-as-library \
    Sources/*.swift -o "build/Murmur-$1"
}

if [[ "$MODE" == "--release" ]]; then
  compile arm64
  compile x86_64
  lipo -create build/Murmur-arm64 build/Murmur-x86_64 -output "$APP/Contents/MacOS/Murmur"
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' certificate found. See the header of this script." >&2
    exit 1
  fi
else
  compile "$(uname -m)"
  mv "build/Murmur-$(uname -m)" "$APP/Contents/MacOS/Murmur"
  # A stable identity keeps macOS permissions between rebuilds; fall back to ad-hoc.
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
  IDENTITY="${IDENTITY:--}"
fi
rm -f build/Murmur-arm64 build/Murmur-x86_64

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
echo "Built $APP ($VERSION), signed with: $IDENTITY"

case "$MODE" in
  --install)
    pkill -x Murmur 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Murmur.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Murmur.app
    echo "Installed ~/Applications/Murmur.app"
    ;;
  --release)
    codesign --force --options runtime --timestamp \
      --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
    # 1) Notarize the app itself and staple its ticket (so it verifies offline).
    echo "Notarizing the app (usually 1–5 minutes)…"
    ditto -c -k --keepParent "$APP" build/Murmur.zip
    xcrun notarytool submit build/Murmur.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/Murmur.zip
    # 2) Package it in a dmg, then notarize and staple the dmg too.
    rm -rf build/dmg "dist/Murmur-$VERSION.dmg"
    mkdir -p dist build/dmg
    cp -R "$APP" build/dmg/
    ln -s /Applications build/dmg/Applications
    hdiutil create -volname "Murmur $VERSION" -srcfolder build/dmg -ov -format UDZO "dist/Murmur-$VERSION.dmg"
    codesign --sign "$IDENTITY" --timestamp "dist/Murmur-$VERSION.dmg"
    echo "Notarizing the dmg…"
    xcrun notarytool submit "dist/Murmur-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "dist/Murmur-$VERSION.dmg"
    spctl --assess --type open --context context:primary-signature -v "dist/Murmur-$VERSION.dmg"
    shasum -a 256 "dist/Murmur-$VERSION.dmg"
    echo "Release ready: dist/Murmur-$VERSION.dmg"
    ;;
esac
