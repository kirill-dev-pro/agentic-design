#!/bin/sh
# Renders assets/icon/icon.svg into assets/icon/AppIcon.icns (committed, so builds and CI
# need neither Chrome nor this script). Needs Google Chrome for the transparent render.
set -eu
cd "$(dirname "$0")/../.."
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '<html><body style="margin:0;background:transparent">%s</body></html>' "$(cat assets/icon/icon.svg)" > "$TMP/icon.html"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
	--user-data-dir="$TMP/chrome" --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$TMP/icon.html" 2>/dev/null
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
	sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
	d=$((s * 2))
	sips -z $d $d "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/icon/AppIcon.icns
cp "$TMP/icon.png" assets/icon/icon-1024.png
echo "wrote assets/icon/AppIcon.icns"
