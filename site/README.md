# agentic-design.kcrz.dev

The website: the landing page and the browser viewer at `/view`. Static files, no
framework.

| Path | |
| --- | --- |
| `src/index.html`, `src/styles.css`, `src/main.js` | the landing page, written by hand after the design in `designs/sample/agentic-design.pen` (its HTML export was the starting point): the same tokens, light and dark (the system's, or the button), desktop and phone layouts |
| `src/fonts/` | Inter and JetBrains Mono, Latin subsets as woff2 (`tools/fonts.py` writes them from `designs/sample/fonts`; OFL) |
| `src/img/og.png` | the Open Graph image: the design's desktop frame rendered by the app (`screenshot`, scale 2), cropped to 1200 × 630 |
| `build.mjs` | `node site/build.mjs` → `site/dist`: hashed asset names, the stylesheet inlined, the viewer from `build/web` (`tools/build_web.sh`) under `/view`, `.br` and `.gz` copies |
| `Caddyfile` | serves `dist` on :3000: precompressed files, immutable caching of hashed names, `/api/health` |
| `bunderstack.blueprint.yaml` | the contract Bunderhost reads before it deploys; it declares nothing the site uses |
| `../Dockerfile.bunderhost` | the image Bunderhost builds: the viewer on the pinned Odin release, the pages, Caddy |

## Run it locally

```sh
./tools/build_web.sh            # the viewer (needs wasm-ld: brew install lld)
node site/build.mjs
SITE_ROOT=site/dist PORT=8080 caddy run --config site/Caddyfile --adapter caddyfile
```

Any static server works too (`python3 -m http.server -d site/dist`), without the
compression and cache headers.

## Deploying

Bunderhost deploys the repository on a push to `main`: it builds `Dockerfile.bunderhost` and
runs the image. The project's root directory is `site`.

## Copy

Keep the page true to what the app does today: the README is the reference. Links:
"Download for macOS" goes to the latest release (the page swaps in the dmg's own URL from
the GitHub API when it loads), "Source" to the repository, "Docs" to `docs/`.
