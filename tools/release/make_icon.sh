#!/bin/sh
# Builds assets/icon/AppIcon.icns from two transparent per-size masters (both committed, as is the .icns, so builds
# and CI need neither this script nor any renderer):
#   assets/icon/icon-1024.png        the 1024 master: 64 px and up (and every @2x of 32 pt and more)
#   assets/icon/icon-small-1024.png  the 16 / 32 px master, simplified for tiny sizes (bigger, wider eyes, a bolder
#                                    moustache, no blush, thicker outlines), drawn at 1024 and scaled down: 16 and 32 px
# Without icon-small-1024.png every size comes from icon-1024.png. icon.svg is the same mark as vector (the site, docs);
# it is not rendered here. The masters are exported from the design file (the Agentic Design dogfooding icon set).
set -eu
cd "$(dirname "$0")/../.."
BIG=assets/icon/icon-1024.png
SMALL=assets/icon/icon-small-1024.png
[ -f "$SMALL" ] || SMALL=$BIG
for f in "$BIG" "$SMALL"; do
	w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')
	h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
	a=$(sips -g hasAlpha "$f" | awk '/hasAlpha/ {print $2}')
	[ "$w" = 1024 ] && [ "$h" = 1024 ] || { echo "$f: expected 1024 x 1024, got $w x $h" >&2; exit 1; }
	[ "$a" = yes ] || { echo "$f: expected a transparent PNG (no alpha channel)" >&2; exit 1; }
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
px() { sips -z "$2" "$2" "$1" --out "$SET/$3" >/dev/null; }
px "$SMALL" 16 icon_16x16.png
px "$SMALL" 32 icon_16x16@2x.png
px "$SMALL" 32 icon_32x32.png
px "$BIG" 64 icon_32x32@2x.png
for s in 128 256 512; do
	px "$BIG" "$s" "icon_${s}x${s}.png"
	px "$BIG" $((s * 2)) "icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o assets/icon/AppIcon.icns
# the "What's new" sheet draws the icon at 56 pt (src/whats_new.odin)
sips -z 112 112 "$BIG" --out assets/icon/icon-112.png >/dev/null
echo "wrote assets/icon/AppIcon.icns (16, 32 px from $(basename "$SMALL"); 64 px and up from $(basename "$BIG"))"
