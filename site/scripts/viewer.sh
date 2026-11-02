#!/bin/sh
# Builds the browser viewer (../tools/build_web.sh -> ../build/web) before the site build.
# Where Odin or wasm-ld are missing (Bunderhost's build image is plain Bun on Debian), it
# fetches the pinned Odin release (as .github/workflows/release.yml pins it) and installs
# lld. SKIP_VIEWER=1 builds the site without /view.
set -e
cd "$(dirname "$0")/../.."
[ "${SKIP_VIEWER:-}" = 1 ] && { echo "viewer: skipped"; exit 0; }

ODIN_VERSION=dev-2026-10
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) ODIN_ASSET=odin-linux-amd64-$ODIN_VERSION.tar.gz ODIN_SHA256=c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab ;;
	Linux-aarch64) ODIN_ASSET=odin-linux-arm64-$ODIN_VERSION.tar.gz ODIN_SHA256=99c43e9670a285901d6cfee5f56197b74c7d6f7c537b35ecba0c1b44ac2e4df8 ;;
	*) ODIN_ASSET= ;;
esac

if ! command -v odin >/dev/null 2>&1; then
	[ -n "$ODIN_ASSET" ] || { echo "viewer: no odin on PATH (brew install odin)" >&2; exit 1; }
	dir=build/odin-$ODIN_VERSION
	if [ ! -x "$dir/odin" ]; then
		echo "viewer: fetching $ODIN_ASSET"
		mkdir -p "$dir"
		bun -e "const r = await fetch('https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/$ODIN_ASSET'); if (!r.ok) throw new Error(r.status); await Bun.write('build/odin.tar.gz', r)"
		echo "$ODIN_SHA256  build/odin.tar.gz" | sha256sum -c -
		tar xzf build/odin.tar.gz -C "$dir" --strip-components=1
		rm build/odin.tar.gz
	fi
	PATH="$PWD/$dir:$PATH"
fi

if ! command -v wasm-ld >/dev/null 2>&1; then
	for d in /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin /usr/lib/llvm-*/bin; do
		[ -x "$d/wasm-ld" ] && PATH="$d:$PATH" && break
	done
fi
if ! command -v wasm-ld >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
	echo "viewer: installing lld"
	apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends lld >/dev/null
	command -v wasm-ld >/dev/null 2>&1 || PATH="$(dirname "$(ls /usr/lib/llvm-*/bin/wasm-ld | head -n 1)"):$PATH"
fi
export PATH
sh tools/build_web.sh
