#!/bin/bash
# Builds build/Tidewall.app: the host, the icon, and the themes (Info.plist, ad-hoc signed).
# To use it: copy it to ~/Applications (or /Applications), open it, and turn on "Open at login" in its Settings.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
VERSION=$(tr -d " \n" < VERSION)          # the one place the version lives (tools/release.sh bumps it)
APP=build/Tidewall.app
# one universal binary: Apple silicon and Intel
FW="-framework Cocoa -framework WebKit -framework IOKit"
# RELEASE=1 (the release workflow) makes a release build; anything else is a development build, which never updates
# itself and is the only kind that honours the TIDEWALL_UPDATE_* test variables
DEV="-D TIDEWALL_DEV"; [ "${RELEASE:-}" = 1 ] && DEV=""
swiftc -O main.swift -target arm64-apple-macos14 -o build/tidewall-arm64 $FW $DEV
swiftc -O main.swift -target x86_64-apple-macos14 -o build/tidewall-x86_64 $FW $DEV
lipo -create build/tidewall-arm64 build/tidewall-x86_64 -output tidewall; rm build/tidewall-arm64 build/tidewall-x86_64
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp tidewall "$APP/Contents/MacOS/Tidewall"
cp assets/Tidewall.icns "$APP/Contents/Resources/Tidewall.icns"
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
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Began as a fork of Deskland.</string>
</dict></plist>
PL
codesign --force --deep --sign - "$APP"                       # ad-hoc; the updater refuses a bundle whose seal is broken
echo "built $APP ($(du -sh "$APP" | cut -f1))"
