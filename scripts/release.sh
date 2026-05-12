#!/usr/bin/env bash
# Builds, signs, and packages Hearth.app for distribution.
#
# Usage:
#   bash scripts/release.sh
#
# Environment overrides:
#   DEV_ID="Developer ID Application: Your Name (TEAM)"   # full sign + notarize
#   NOTARIZE_PROFILE="MyAltoolKeychainProfile"            # see `xcrun notarytool store-credentials`
#   SKIP_DMG=1                                            # only emit a zip, no dmg
#
# Outputs everything into ./dist:
#   - Hearth.app          (signed)
#   - Hearth-1.0.0.zip    (the .app, zipped)
#   - Hearth-1.0.0.dmg    (optional, if create-dmg or hdiutil is available)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Hearth/Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Hearth/Resources/Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Hearth/Resources/Info.plist 2>/dev/null \
            || echo "com.colbydimaggio.hearth")
NAME=Hearth
DIST=./dist
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▶ Hearth $VERSION (build $BUILD)"
mkdir -p "$DIST"
rm -rf "$DIST/$NAME.app" "$DIST/$NAME-$VERSION.zip" "$DIST/$NAME-$VERSION.dmg"

echo "▶ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "▶ Building Release"
xcodebuild \
  -project "$NAME.xcodeproj" \
  -scheme "$NAME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$TMP/dd" \
  clean build \
  | xcbeautify 2>/dev/null \
  || xcodebuild \
       -project "$NAME.xcodeproj" \
       -scheme "$NAME" \
       -configuration Release \
       -destination 'platform=macOS' \
       -derivedDataPath "$TMP/dd" \
       clean build \
       | tail -20

BUILT_APP="$TMP/dd/Build/Products/Release/$NAME.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "✗ Release build is missing — bailing"
  exit 1
fi
cp -R "$BUILT_APP" "$DIST/$NAME.app"
APP="$DIST/$NAME.app"

# ---- Sign ----
if [ -n "${DEV_ID:-}" ]; then
  echo "▶ Signing with Developer ID: $DEV_ID"
  codesign --force --deep --options runtime \
    --entitlements Hearth/Resources/Hearth.entitlements \
    --sign "$DEV_ID" \
    "$APP"
else
  echo "▶ Ad-hoc signing (set DEV_ID env var for Developer ID signing)"
  codesign --force --deep --options runtime \
    --entitlements Hearth/Resources/Hearth.entitlements \
    --sign - \
    "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "✓ codesign verify OK"

# ---- Notarize (optional) ----
if [ -n "${DEV_ID:-}" ] && [ -n "${NOTARIZE_PROFILE:-}" ]; then
  echo "▶ Notarizing"
  NOTARIZE_ZIP="$TMP/notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait \
    --timeout 30m
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" && echo "✓ stapled"
elif [ -n "${DEV_ID:-}" ]; then
  echo "ℹ Skipping notarization — set NOTARIZE_PROFILE to enable"
fi

# ---- Zip ----
ZIP="$DIST/$NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"

# ---- DMG (optional) ----
if [ "${SKIP_DMG:-0}" != "1" ]; then
  DMG="$DIST/$NAME-$VERSION.dmg"
  if command -v create-dmg >/dev/null 2>&1; then
    echo "▶ DMG via create-dmg"
    create-dmg \
      --volname "$NAME $VERSION" \
      --window-pos 200 120 --window-size 600 400 \
      --icon-size 100 \
      --icon "$NAME.app" 175 200 \
      --app-drop-link 425 200 \
      "$DMG" "$APP" >/dev/null 2>&1 || true
  fi
  # Fallback to hdiutil if create-dmg isn't installed or failed.
  if [ ! -f "$DMG" ]; then
    echo "▶ DMG via hdiutil"
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" \
      -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
  fi
  echo "✓ $DMG"
fi

echo
echo "▶ Done. Artifacts in $DIST/"
ls -lh "$DIST"
