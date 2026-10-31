#!/bin/sh
# Builds build/agentic-design. Pass -o:speed for an optimized build.
set -e
cd "$(dirname "$0")"
mkdir -p build
odin build src -out:build/agentic-design "${@:--debug}"
