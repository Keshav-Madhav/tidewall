#!/bin/bash
# Builds build/Tidewall.app: the host, the icon, and the themes (Info.plist; signed, see the end).
# To use it: copy it to ~/Applications (or /Applications), open it, and turn on "Open at login" in its Settings.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
VERSION=$(tr -d " \n" < VERSION)          # the one place the version lives (tools/release.sh bumps it)
APP=build/Tidewall.app
# one universal binary: Apple silicon and Intel
FW="-framework Cocoa -framework WebKit -framework IOKit -framework CoreLocation"
# RELEASE=1 (the release workflow) makes a release build; anything else is a development build, which never updates
# itself and is the only kind that honours the TIDEWALL_UPDATE_* test variables
DEV="-D TIDEWALL_DEV"; [ "${RELEASE:-}" = 1 ] && DEV=""
SRC=$(find Sources -name '*.swift' | sort)
swiftc -O $SRC -target arm64-apple-macos14 -o build/tidewall-arm64 $FW $DEV
swiftc -O $SRC -target x86_64-apple-macos14 -o build/tidewall-x86_64 $FW $DEV
lipo -create build/tidewall-arm64 build/tidewall-x86_64 -output tidewall; rm build/tidewall-arm64 build/tidewall-x86_64
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp tidewall "$APP/Contents/MacOS/Tidewall"
cp assets/Tidewall.icns "$APP/Contents/Resources/Tidewall.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"            # the app's What's New page reads it
# the themes
rsync -a --delete --exclude .DS_Store themes/ "$APP/Contents/Resources/themes/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tidewall</string>
  <key>CFBundleDisplayName</key><string>Tidewall</string>
  <key>CFBundleIdentifier</key><string>app.tidewall</string>
  <key>CFBundleExecutable</key><string>Tidewall</string>
  <key>CFBundleIconFile</key><string>Tidewall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.lifestyle</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>Tidewall draws the real sky over you: the sun and shadows in Courtyard, the stars in Celestial Atlas, rising and setting when they really do where you are. Your location is rounded to about 10 km and stays on this Mac.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Tidewall draws the real sky over you: the sun and shadows in Courtyard, the stars in Celestial Atlas, rising and setting when they really do where you are. Your location is rounded to about 10 km and stays on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Tidewall asks Finder where your desktop icons are, so the wallpaper can make room for them. It reads their positions only, nothing else.</string>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Began as a fork of Deskland.</string>
</dict></plist>
PL
# Releases are signed with Tidewall's own certificate (assets/tidewall-signing-cert.pem; the release workflow puts it in
# a throwaway keychain and sets TIDEWALL_SIGN_ID to its SHA-1). Every release then has the same identity, so macOS keeps
# the permissions you gave Tidewall (Finder, for the desktop icons) across updates. Anything else is signed ad hoc.
# Either way the updater refuses a bundle whose seal is broken.
if [ -n "${TIDEWALL_SIGN_ID:-}" ]; then
  codesign --force --deep --timestamp=none --sign "$TIDEWALL_SIGN_ID" ${TIDEWALL_SIGN_KEYCHAIN:+--keychain "$TIDEWALL_SIGN_KEYCHAIN"} "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "built $APP ($(du -sh "$APP" | cut -f1))"
