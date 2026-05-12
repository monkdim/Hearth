#!/usr/bin/env bash
# Generates Ember's app icon at every macOS-required size and writes them into
# Assets.xcassets/AppIcon.appiconset, along with a matching Contents.json.
#
# Usage: bash scripts/build-iconset.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET_DIR="Ember/Resources/Assets.xcassets/AppIcon.appiconset"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Rendering 1024×1024 master"
swift scripts/generate-icon.swift "$TMP_DIR/icon_1024.png"

mkdir -p "$ICONSET_DIR"

# Sizes the macOS AppIcon catalog wants (filename → pixel dimension).
declare -a SIZES=(
  "icon_16x16:16"
  "icon_16x16@2x:32"
  "icon_32x32:32"
  "icon_32x32@2x:64"
  "icon_128x128:128"
  "icon_128x128@2x:256"
  "icon_256x256:256"
  "icon_256x256@2x:512"
  "icon_512x512:512"
  "icon_512x512@2x:1024"
)

for entry in "${SIZES[@]}"; do
  name="${entry%%:*}"
  px="${entry##*:}"
  echo "→ $name (${px}×${px})"
  sips -z "$px" "$px" "$TMP_DIR/icon_1024.png" --out "$ICONSET_DIR/${name}.png" >/dev/null
done

cat > "$ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",      "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",      "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",    "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",    "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",    "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png", "scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "ember" }
}
JSON

echo "✓ Iconset built at $ICONSET_DIR"
