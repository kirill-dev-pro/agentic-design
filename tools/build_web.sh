#!/bin/sh
# Builds the browser viewer into build/web: viewer.wasm (src/web, the engine on the
# browser's WebGPU), the page (web/) and Odin's JavaScript glue. Pass -debug for a debug
# build. Serve the repository and open the page with a document on the same server:
#   python3 -m http.server 8000
#   http://localhost:8000/build/web/?file=/designs/sample/agentic-design.pen
# Linking WebAssembly needs LLVM's wasm-ld (Homebrew: brew install lld).
set -e
cd "$(dirname "$0")/.."
if ! command -v wasm-ld >/dev/null 2>&1; then
	for d in /opt/homebrew/opt/lld/bin /opt/homebrew/opt/lld@*/bin /usr/local/opt/lld/bin; do
		[ -x "$d/wasm-ld" ] && PATH="$d:$PATH" && break
	done
fi
command -v wasm-ld >/dev/null 2>&1 || { echo "build_web.sh: wasm-ld not found (brew install lld)" >&2; exit 1; }
mkdir -p build/web
# --export-table: wgpu.js calls the module's callbacks through its function table
odin build src/web -target:js_wasm32 -out:build/web/viewer.wasm -extra-linker-flags:"--export-table" "${@:--o:speed}"
cp web/index.html web/viewer.js web/upload.js web/viewer.css web/sw.js build/web/
cp "$(odin root)/core/sys/wasm/js/odin.js" build/web/
cp src/wgpu/wgpu.js build/web/
