#!/bin/sh
# Type-checks the app for the other desktop systems from this machine, in about a second:
# Linux (odin check) and Windows (compiled to an object file, which odin needs a Windows SDK
# folder for; an empty one does, since nothing is linked). The libraries those builds link
# (wgpu-native, Odin's stb) are not needed: their "could not find the compiled library"
# panics are left out, every other error fails the check. build.sh runs it after a build;
# CI builds and links the real thing on Linux and Windows (.github/workflows/ci.yml).
#
#   tools/check_targets.sh                 linux_amd64 and windows_amd64
#   tools/check_targets.sh linux_arm64     the targets named
set -e
cd "$(dirname "$0")/.."
TARGETS=${*:-linux_amd64 windows_amd64}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sdk"
failed=0
for t in $TARGETS; do
	case "$t" in
	windows_*) odin build src -target:"$t" -windows-sdk-root:"$TMP/sdk" -build-mode:obj -out:"$TMP/app.obj" >"$TMP/out" 2>&1 || true ;;
	*) odin check src -target:"$t" >"$TMP/out" 2>&1 || true ;;
	esac
	# an error is a line with "Error:" and the indented source lines under it
	awk '/Error:/ { keep = ($0 !~ /Could not find the compiled/) } keep' "$TMP/out" >"$TMP/errors"
	if grep -q "Error:" "$TMP/errors"; then
		echo "check_targets.sh: $t does not build:" >&2
		sed "s|$(pwd)/||" "$TMP/errors" >&2
		failed=1
	fi
done
exit $failed
