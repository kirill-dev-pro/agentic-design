#!/bin/sh
# Downloads wgpu-native into src/wgpu/lib/ (see src/wgpu/README.md). build.sh runs it;
# an OpenGL build (-define:RENDERER=gl) does not need it.
set -e
cd "$(dirname "$0")/.."
VERSION=v29.0.1.1
case "$(uname -s)-$(uname -m)" in
Darwin-arm64) NAME=wgpu-macos-aarch64-release; SHA=a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e ;;
*) echo "fetch_wgpu.sh: no pinned wgpu-native build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
DEST=src/wgpu/lib/$NAME
if [ -f "$DEST/lib/libwgpu_native.a" ]; then echo "$DEST is there"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/wgpu.zip" "https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION/$NAME.zip"
echo "$SHA  $TMP/wgpu.zip" | shasum -a 256 -c -
mkdir -p "$DEST"
unzip -q "$TMP/wgpu.zip" -d "$TMP/x"
cp -R "$TMP/x/lib" "$DEST/"
echo "wgpu-native $VERSION in $DEST"
