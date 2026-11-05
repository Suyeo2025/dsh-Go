#!/bin/zsh
# Render the iOS AppIcon (single size 1024: light, dark and tinted appearances) from the brand tile.
# Runs on the Mac (needs homebrew rsvg-convert + magick). Usage, from the repo root on the Mac:
#   zsh tooling/ios/make-app-icon.sh
# - light (the App Store icon): the rounded tile path in app/assets/brand/tile.svg becomes a
#   full-bleed square (iOS applies its own mask) and the PNG has no alpha channel.
# - dark: the glyph alone on transparency; iOS puts it on its dark background.
# - tinted: the glyph in grayscale on transparency; iOS colours it with the chosen tint.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
ROOT=${0:A:h:h:h}
SRC=$ROOT/app/assets/brand/tile.svg
OUT=$ROOT/app/ios/Runner/Assets.xcassets/AppIcon.appiconset
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TILE='<path id="tile" fill="url\(\#tile-bg\)" d="[^"]*"/>'

perl -0pe "s#$TILE#<rect id=\"tile\" x=\"18\" y=\"18\" width=\"72\" height=\"72\" fill=\"url(\\#tile-bg)\"/>#" "$SRC" > "$TMP/icon.svg"
grep -q '<rect id="tile"' "$TMP/icon.svg" || { echo "tile path not found in $SRC" >&2; exit 1; }
perl -0pe "s#$TILE##" "$SRC" > "$TMP/glyph.svg"
grep -q 'id="tile"' "$TMP/glyph.svg" && { echo "tile path not removed" >&2; exit 1; }

rsvg-convert -w 1024 -h 1024 "$TMP/icon.svg" -o "$TMP/icon-rgba.png"
rsvg-convert -w 1024 -h 1024 "$TMP/glyph.svg" -o "$TMP/glyph.png"
rm -rf "$OUT"; mkdir -p "$OUT"
# Flatten onto the gradient's dark end (never visible: the square is fully covered) and drop alpha.
magick "$TMP/icon-rgba.png" -background '#405AAD' -alpha remove -alpha off -define png:color-type=2 "$OUT/AppIcon-1024.png"
cp "$TMP/glyph.png" "$OUT/AppIcon-1024-dark.png"
# Tinted: luminance, stretched so the lightest part of the glyph is white.
magick "$TMP/glyph.png" -channel RGB -colorspace Gray -auto-level +channel "$OUT/AppIcon-1024-tinted.png"

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "AppIcon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "AppIcon-1024-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
for f in "$OUT"/*.png; do sips -g pixelWidth -g hasAlpha "$f" | tr '\n' ' '; echo; done
