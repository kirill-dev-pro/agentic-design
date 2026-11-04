#!/bin/sh
# Builds the browser viewer (../tools/build_web.sh -> ../build/web) before the site build.
#
# The compiled part (viewer.wasm, odin.js, the editor's editor.wasm, and the server engine
# pencore.wasm that the Worker bundles from site/src/room/) comes from CI: .github/workflows/ci.yml compiles it
# on every push and uploads it to the web-viewer-builds prerelease under a key, a hash of its
# sources (scripts/viewer-key.mjs). Here it is fetched by that key and checked against its
# sha256, so the site build downloads no toolchain. When this push's build is not uploaded yet,
# it waits for CI (VIEWER_WAIT seconds, 600 by default; none where Odin and wasm-ld are on
# PATH). Without a prebuilt viewer it compiles: with the local Odin and wasm-ld, or (Bunderhost's
# image is plain Bun on Debian) the pinned Odin release and Debian's lld, each step with a time
# limit. VIEWER_BUILD=local always compiles; SKIP_VIEWER=1 builds the site without /view.
set -e
cd "$(dirname "$0")/../.."
# the Worker imports the server engine at build time: where there is none, an empty module
# keeps the import resolving (the room says so when it is asked to run)
PENCORE=site/src/room/pencore.wasm
empty_pencore() { [ -f "$PENCORE" ] || { mkdir -p "$(dirname "$PENCORE")" && printf '\000asm\001\000\000\000' > "$PENCORE"; }; }
[ "${SKIP_VIEWER:-}" = 1 ] && { empty_pencore; echo "viewer: skipped"; exit 0; }

# the same Odin release as .github/workflows/ci.yml and release.yml
ODIN_VERSION=dev-2026-10
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) ODIN_ASSET=odin-linux-amd64-$ODIN_VERSION.tar.gz ODIN_SHA256=c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab ;;
	Linux-aarch64) ODIN_ASSET=odin-linux-arm64-$ODIN_VERSION.tar.gz ODIN_SHA256=99c43e9670a285901d6cfee5f56197b74c7d6f7c537b35ecba0c1b44ac2e4df8 ;;
	*) ODIN_ASSET= ;;
esac

# runs "$@" for at most $1 seconds where timeout(1) exists
limit() { s=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

if ! command -v wasm-ld >/dev/null 2>&1; then
	for d in /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin /usr/lib/llvm-*/bin; do
		[ -x "$d/wasm-ld" ] && PATH="$d:$PATH" && break
	done
fi
toolchain=0
command -v odin >/dev/null 2>&1 && command -v wasm-ld >/dev/null 2>&1 && toolchain=1

if [ "${VIEWER_BUILD:-}" != local ]; then
	key=$(ODIN_VERSION=$ODIN_VERSION node site/scripts/viewer-key.mjs)
	wait=${VIEWER_WAIT:-600}
	[ $toolchain = 1 ] && wait=0
	echo "viewer: prebuilt key $key"
	rm -rf build/viewer-prebuilt && mkdir -p build/viewer-prebuilt
	if node site/scripts/viewer-fetch.mjs "$key" build/viewer-prebuilt/viewer.tar.gz "$wait"; then
		tar xzf build/viewer-prebuilt/viewer.tar.gz -C build/viewer-prebuilt
		if [ -f build/viewer-prebuilt/pencore/pencore.wasm ]; then
			VIEWER_PREBUILT=$PWD/build/viewer-prebuilt sh tools/build_web.sh
			mkdir -p "$(dirname "$PENCORE")" && cp build/viewer-prebuilt/pencore/pencore.wasm "$PENCORE"
			exit 0
		fi
		echo "viewer: the prebuilt archive has no pencore.wasm"
	fi
	echo "viewer: no prebuilt viewer for $key; compiling"
fi

if ! command -v odin >/dev/null 2>&1; then
	[ -n "$ODIN_ASSET" ] || { echo "viewer: no odin on PATH (brew install odin)" >&2; exit 1; }
	dir=build/odin-$ODIN_VERSION
	if [ ! -x "$dir/odin" ]; then
		echo "viewer: fetching $ODIN_ASSET"
		mkdir -p "$dir"
		bun -e "const r = await fetch('https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/$ODIN_ASSET', { signal: AbortSignal.timeout(300000) }); if (!r.ok) throw new Error('HTTP ' + r.status); await Bun.write('build/odin.tar.gz', r)" \
			|| { echo "viewer: fetching Odin failed or took over 5 minutes" >&2; exit 1; }
		echo "$ODIN_SHA256  build/odin.tar.gz" | sha256sum -c -
		tar xzf build/odin.tar.gz -C "$dir" --strip-components=1
		rm build/odin.tar.gz
	fi
	PATH="$PWD/$dir:$PATH"
fi

if ! command -v wasm-ld >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
	echo "viewer: installing lld"
	export DEBIAN_FRONTEND=noninteractive
	{ limit 300 apt-get update -qq >/dev/null && limit 300 apt-get install -y -qq --no-install-recommends lld >/dev/null; } \
		|| { echo "viewer: installing lld failed or took over 5 minutes" >&2; exit 1; }
	command -v wasm-ld >/dev/null 2>&1 || PATH="$(dirname "$(ls /usr/lib/llvm-*/bin/wasm-ld | head -n 1)"):$PATH"
fi
export PATH
limit 900 sh tools/build_web.sh || { echo "viewer: compiling failed or took over 15 minutes" >&2; exit 1; }
limit 120 sh tools/build_pencore.sh || { echo "viewer: compiling pencore failed or took over 2 minutes" >&2; exit 1; }
mkdir -p "$(dirname "$PENCORE")" && cp build/pencore/pencore.wasm "$PENCORE"
