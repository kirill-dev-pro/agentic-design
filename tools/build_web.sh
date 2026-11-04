#!/bin/sh
# Builds the browser viewer into build/web: viewer.wasm (src/web, the engine on the
# browser's WebGPU), the page (web/) and Odin's JavaScript glue, and the browser editor in
# build/web/edit: editor.wasm (src, the app's interface on the same engine) and its page
# (web/edit). Pass -debug for a debug build. Serve the repository and open the page with a
# document on the same server:
#   python3 -m http.server 8000
#   http://localhost:8000/build/web/?file=/designs/sample/agentic-design.pen
# Linking WebAssembly needs LLVM's wasm-ld (Homebrew: brew install lld).
# VIEWER_PREBUILT=<dir> takes viewer.wasm, editor.wasm and odin.js from <dir> instead of
# compiling them: what CI compiled for the same sources (site/scripts/viewer.sh).
set -e
cd "$(dirname "$0")/.."
mkdir -p build/web/edit
if [ -n "${VIEWER_PREBUILT:-}" ]; then
	cp "$VIEWER_PREBUILT/viewer.wasm" "$VIEWER_PREBUILT/odin.js" build/web/
	cp "$VIEWER_PREBUILT/edit/editor.wasm" build/web/edit/
else
	if ! command -v wasm-ld >/dev/null 2>&1; then
		for d in /opt/homebrew/opt/lld/bin /opt/homebrew/opt/lld@*/bin /usr/local/opt/lld/bin; do
			[ -x "$d/wasm-ld" ] && PATH="$d:$PATH" && break
		done
	fi
	command -v wasm-ld >/dev/null 2>&1 || { echo "build_web.sh: wasm-ld not found (brew install lld)" >&2; exit 1; }
	# --export-table: wgpu.js calls the module's callbacks through its function table
	odin build src/web -target:js_wasm32 -out:build/web/viewer.wasm -extra-linker-flags:"--export-table" "${@:--o:speed}"
	# the editor is the app's own package (src), entered at src/editor_web.odin
	odin build src -target:js_wasm32 -out:build/web/edit/editor.wasm -extra-linker-flags:"--export-table" "${@:--o:speed}"
	cp "$(odin root)/core/sys/wasm/js/odin.js" build/web/
fi
cp web/index.html web/viewer.js web/upload.js web/viewer.css web/sw.js build/web/
cp src/wgpu/wgpu.js build/web/
cp web/edit/index.html web/edit/editor.js web/edit/editor.css web/edit/keys.js web/edit/store.js build/web/edit/
cp build/web/odin.js build/web/wgpu.js build/web/edit/
