# agentic-design.kcrz.dev

The website: the landing page, the browser viewer at `/view`, and an API under `/api` that
is empty for now (sharing, accounts and the web editor will use it). It is a
[Workerstack](https://github.com/kirill-dev-pro/workerstack) app on Cloudflare Workers,
hosted by Bunderhost: the pages and the viewer are the Worker's static assets, the Worker
answers `/api/*`.

| Path | |
| --- | --- |
| `pages/index.html`, `pages/styles.css`, `pages/main.js` | the landing page, written by hand after the design in `designs/sample/agentic-design.pen` (its HTML export was the starting point): the same tokens, light and dark (the system's, or the button), desktop and phone layouts |
| `pages/fonts/` | Inter and JetBrains Mono, Latin subsets as woff2 (`tools/fonts.py` writes them from `designs/sample/fonts`; OFL) |
| `pages/favicon.*`, `pages/img/apple-touch-icon.png`, `pages/img/icon-*.png`, `pages/img/logo-*.png` | the app icon's web set (from the Dogfooder's final icon set): the favicons from the small-size master (the SVG switches light and dark with the system), the touch and manifest icons, and the logo in the nav and footer (32 px from the small master, 64 and 96 px from the 1024 one, light and dark) |
| `pages/img/og.png` | the Open Graph card: the app icon on cream, 1200 × 630, from the icon set |
| `build.mjs` | `node build.mjs` → `dist/client`: the pages with hashed asset names and the stylesheet inlined, the viewer from `../build/web` under `/view` with the sample design, and `_headers` (hashed names are immutable). Plain files that any static host can serve |
| `scripts/viewer.sh` | builds the viewer (`../tools/build_web.sh`); where Odin or `wasm-ld` are missing (Bunderhost's build image) it fetches the pinned Odin release and installs `lld` |
| `src/workerstack.ts`, `src/schema.ts` | the backend: no tables of its own yet, one route (`GET /api/version`) |
| `migrations/`, `workerstack.blueprint.yaml` | Workerstack's tables and the deployment contract Bunderhost reads (`bun run db:generate`, `bun run blueprint`) |

The repository root has a `package.json` naming `site` as its only workspace, and the
`bun.lock`: Bunderhost installs dependencies from the root.

## Build and run locally

```sh
bun install                      # at the repository root
cd site
bun run build                    # viewer, Worker (dist/server), pages (dist/client)
node build.mjs                   # the pages and viewer only, after ../tools/build_web.sh
python3 -m http.server -d dist/client 8080   # the static part, without the API
```

`bun run build` needs Odin and `wasm-ld` (`brew install odin lld`), or `SKIP_VIEWER=1`.

## Deploying

Bunderhost deploys a push to `main` on its Cloudflare target: `bun install` at the root,
`bun run build` here, then the Worker from `dist/server` with `dist/client` as its assets.
Cloudflare compresses responses (brotli or gzip) and serves `.wasm` as `application/wasm`.
After changing `src/`, run `bun run db:generate` and `bun run blueprint` and commit both.

## Copy

Keep the page true to what the app does today: the README is the reference. Links:
"Download for macOS" goes to the latest release (the page swaps in the dmg's own URL from
the GitHub API when it loads), "Source" to the repository, "Docs" to `docs/`.
