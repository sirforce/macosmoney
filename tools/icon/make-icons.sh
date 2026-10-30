#!/bin/bash
# Renders the app icon and writes every size macOS needs into the asset catalog.
set -euo pipefail
cd "$(dirname "$0")/../.."
SET=App/MacMoney/Assets.xcassets/AppIcon.appiconset
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O tools/icon/AppIcon.swift -o "$WORK/appicon" 2>/dev/null
"$WORK/appicon" "$WORK" >/dev/null
mkdir -p "$SET"
for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$WORK/AppIcon-1024.png" --out "$SET/icon_${px}.png" >/dev/null
done
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > App/MacMoney/Assets.xcassets/Contents.json
echo "Wrote $SET"
