#!/bin/sh
# Builds build/pencore/pencore.wasm: the engine's document model, the cloud protocol's ops
# (src/engine/ops.odin) and the .pen serializer, for the server's DocRoom (cloud-ops.md §7).
# No GPU, files or network; the host provides four imports (odin_env: cos, sin, write,
# rand_bytes). Loader and vector runner: agentic-design-tests tests/cloud-ops/pencore*.mjs.
set -e
cd "$(dirname "$0")/.."
if ! command -v wasm-ld >/dev/null 2>&1; then
	for d in /opt/homebrew/opt/lld/bin /opt/homebrew/opt/lld@*/bin /usr/local/opt/lld/bin; do
		[ -x "$d/wasm-ld" ] && PATH="$d:$PATH" && break
	done
fi
mkdir -p build/pencore
odin build src/pencore -target:js_wasm32 -out:build/pencore/pencore.wasm "${@:--o:speed}"
