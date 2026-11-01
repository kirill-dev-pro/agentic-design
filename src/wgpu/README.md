# wgpu (vendored)

Odin's `vendor:wgpu` bindings (Odin dev-2026-10, zlib licence like Odin) for
[wgpu-native](https://github.com/gfx-rs/wgpu-native) v29.0.1.1 (MIT or Apache-2.0),
kept here so the version of the bindings and of the library always match.

The native library is not in the repository (34 MB). `tools/fetch_wgpu.sh` downloads the
release archive, checks its SHA-256 and unpacks the static library into `lib/`, where
`wgpu.odin` links it from. The browser build uses `wgpu.js` and the browser's WebGPU
instead.
