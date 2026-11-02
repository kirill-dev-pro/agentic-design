# agentic-design.kcrz.dev

The website: the landing page and the browser viewer at `/view`. Plain static files built
into `site/dist` and published on GitHub Pages by `.github/workflows/pages.yml`.

| Path | |
| --- | --- |
| `pages/index.html`, `pages/styles.css`, `pages/main.js` | the landing page, written by hand after the design in `designs/sample/agentic-design.pen` (its HTML export was the starting point): the same tokens, light and dark (the system's, or the button), desktop and phone layouts |
| `pages/fonts/` | Inter and JetBrains Mono, Latin subsets as woff2 (`tools/fonts.py` writes them from `designs/sample/fonts`; OFL) |
| `pages/favicon.ico`, `pages/img/icon*` | the app icon (`assets/icon`): the ico's 16 and 32 px from `icon-small-1024.png`, 48 px and up from `icon-1024.png`, the SVG as is; the touch icon full bleed |
| `pages/img/og.png` | the Open Graph image: the design's desktop frame rendered by the app (`screenshot`, scale 2), cropped to 1200 × 630 |
| `build.mjs` | `node site/build.mjs` → `site/dist`: the pages with the stylesheet inlined, the viewer from `build/web` under `/view` with the sample design, the `CNAME` file. Every other asset has a content hash in its name, since Pages takes no cache headers |

## Build and run locally

```sh
./tools/build_web.sh             # the viewer (needs Odin and wasm-ld: brew install odin lld)
node site/build.mjs              # -> site/dist
python3 -m http.server -d site/dist 8080
```

## Deploying

A push to `main` that touches the site, the viewer or the engine runs the Pages workflow:
the pinned Odin release (as `release.yml` pins it) builds the viewer, `site/build.mjs` the
site, and `actions/deploy-pages` publishes `site/dist`. The custom domain is set in the
repository's Pages settings and by `site/dist/CNAME`; DNS is a CNAME `agentic-design` →
`kirill-dev-pro.github.io` (DNS only) in Cloudflare.

## Copy

Keep the page true to what the app does today: the README is the reference. Links:
"Download for macOS" goes to the latest release (the page swaps in the dmg's own URL from
the GitHub API when it loads), "Source" to the repository, "Docs" to `docs/`.
