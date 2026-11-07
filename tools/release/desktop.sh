#!/bin/sh
# The Linux and Windows build (x86-64), for CI and releases: an optimized binary, checked
# (its MCP server must list its tools), packed into dist/ beside the licences:
#
#   Linux:    dist/Agentic-Design-<version>-linux-x86_64.tar.gz
#   Windows:  dist/Agentic-Design-<version>-windows-x86_64.zip
#
# The workflows install Odin (and on Linux, GLFW, zlib and Odin's stb libraries) first.
#   ODIN=/path/to/odin tools/release/desktop.sh [extra odin flags]
set -eu
cd "$(dirname "$0")/../.."
ODIN=${ODIN:-odin}
VERSION=$(sed -n 's/^VERSION :: #config(VERSION, "\(.*\)")$/\1/p' src/version.odin)
case "$(uname -s)" in
Linux) OS=linux EXE=agentic-design PY=python3 ;;
MINGW* | MSYS* | CYGWIN*) OS=windows EXE=agentic-design.exe PY=python ;;
*) echo "desktop.sh: builds for Linux or Windows, not $(uname -s)" >&2; exit 1 ;;
esac
./tools/fetch_wgpu.sh >/dev/null
mkdir -p build/release dist
# a Windows GUI program: no console window opens with it (stdio still works through pipes,
# as an MCP client starts it)
if [ "$OS" = windows ]; then set -- -subsystem:windows "$@"; fi
"$ODIN" build src -out:"build/release/$EXE" -o:speed "$@"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | AGENTIC_PORT=1 "build/release/$EXE" mcp |
	"$PY" -I -c 'import sys, json; t = json.loads(sys.stdin.readline())["result"]["tools"]; print(len(t), "MCP tools")'
NAME="Agentic-Design-$VERSION-$OS-x86_64"
rm -rf "dist/$NAME"
mkdir -p "dist/$NAME"
cp "build/release/$EXE" LICENSE THIRD_PARTY_NOTICES.md "dist/$NAME/"
if [ "$OS" = linux ]; then
	tar czf "dist/$NAME.tar.gz" -C dist "$NAME"
	echo "dist/$NAME.tar.gz"
else
	rm -f "dist/$NAME.zip"
	(cd dist && 7z a -bso0 "$NAME.zip" "$NAME")
	echo "dist/$NAME.zip"
fi
rm -rf "dist/$NAME"
