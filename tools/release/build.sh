#!/bin/sh
# The release build: an optimized binary for Apple Silicon and macOS 14+, bundled and
# packed by bundle.sh into dist/ (docs/releasing.md).
#
#   ODIN=/path/to/odin tools/release/build.sh [extra odin flags]
#
# UPDATE_FEED overrides where the app looks for updates (the workflow sets it from the
# repository). Use the official Odin release, not Homebrew's: Homebrew links GLFW built for
# the newest macOS, the release ships one built for 14.0.
set -eu
cd "$(dirname "$0")/../.."
ODIN=${ODIN:-odin}
./tools/fetch_wgpu.sh >/dev/null
mkdir -p build/release dist
set -- -o:speed -minimum-os-version:14.0 "$@"
if [ -n "${UPDATE_FEED:-}" ]; then set -- "$@" "-define:UPDATE_FEED=$UPDATE_FEED"; fi
"$ODIN" build src -out:build/release/agentic-design "$@"
# the MCP tool list must parse (as build.sh checks)
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | AGENTIC_PORT=1 build/release/agentic-design mcp |
	python3 -I -c 'import sys, json; json.loads(sys.stdin.readline())["result"]["tools"]'
tools/release/bundle.sh build/release/agentic-design dist
