#!/bin/sh
# Builds build/agentic-design. Pass -o:speed for an optimized build, and
# -define:RENDERER=gl to draw with OpenGL instead of WebGPU (docs/architecture.md).
set -e
cd "$(dirname "$0")"
mkdir -p build
case " $* " in
*RENDERER=gl*) ;;
*) ./tools/fetch_wgpu.sh >/dev/null ;; # wgpu-native, downloaded once
esac
odin build src -out:build/agentic-design "${@:--debug}"
# The MCP tool list is hand-written JSON (src/mcp.odin TOOLS_JSON): a stray quote makes
# strict clients (Claude Code, Codex) drop every tool, so the build checks that it parses.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | AGENTIC_PORT=1 ./build/agentic-design mcp |
	python3 -I -c 'import sys, json; json.loads(sys.stdin.readline())["result"]["tools"]' ||
	{ echo "build.sh: tools/list is not valid JSON (src/mcp.odin TOOLS_JSON)" >&2; exit 1; }
# The same sources must still build for Linux and Windows (checked from here in a second;
# CI links them). AGENTIC_SKIP_TARGETS=1 skips it.
[ -n "$AGENTIC_SKIP_TARGETS" ] || ./tools/check_targets.sh
