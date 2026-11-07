#!/bin/sh
# Downloads wgpu-native into src/wgpu/lib/ (see src/wgpu/README.md). build.sh runs it;
# an OpenGL build (-define:RENDERER=gl) does not need it.
#
#   tools/fetch_wgpu.sh                  the library for this machine
#   tools/fetch_wgpu.sh linux_amd64      another target's (as odin's -target names it), so
#                                        tools/check_targets.sh can check it from a Mac
set -e
cd "$(dirname "$0")/.."
VERSION=v29.0.1.1
TARGET=${1:-}
if [ -z "$TARGET" ]; then
	case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) TARGET=darwin_arm64 ;;
	Linux-x86_64) TARGET=linux_amd64 ;;
	Linux-aarch64 | Linux-arm64) TARGET=linux_arm64 ;;
	MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) TARGET=windows_amd64 ;;
	*) echo "fetch_wgpu.sh: no pinned wgpu-native build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
	esac
fi
LIB=libwgpu_native.a
case "$TARGET" in
darwin_arm64) NAME=wgpu-macos-aarch64-release; SHA=a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e ;;
linux_amd64) NAME=wgpu-linux-x86_64-release; SHA=95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a ;;
linux_arm64) NAME=wgpu-linux-aarch64-release; SHA=015fcdf1dbae82e614a783cc38017e5399ae0927a889fe9b69c9b664bc61b47a ;;
windows_amd64) NAME=wgpu-windows-x86_64-msvc-release; SHA=7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132; LIB=wgpu_native.lib ;;
*) echo "fetch_wgpu.sh: no pinned wgpu-native build for $TARGET" >&2; exit 1 ;;
esac
DEST=src/wgpu/lib/$NAME
if [ -f "$DEST/lib/$LIB" ]; then echo "$DEST is there"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/wgpu.zip" "https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION/$NAME.zip"
if command -v sha256sum >/dev/null; then echo "$SHA  $TMP/wgpu.zip" | sha256sum -c -
else echo "$SHA  $TMP/wgpu.zip" | shasum -a 256 -c -; fi
mkdir -p "$DEST/lib"
if command -v unzip >/dev/null; then unzip -q "$TMP/wgpu.zip" -d "$TMP/x"
else python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$TMP/wgpu.zip" "$TMP/x"; fi
# the static library is all the build links (not the .dll, .so or .pdb beside it)
cp "$TMP/x/lib/$LIB" "$DEST/lib/"
echo "wgpu-native $VERSION in $DEST"
