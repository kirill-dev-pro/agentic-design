# agentic-design.kcrz.dev

The website: the landing page, the browser viewer at `/view`, and an API under `/api`
(accounts, shared files and share links; later cloud documents). It is a
[Workerstack](https://github.com/kirill-dev-pro/workerstack) app on Cloudflare Workers,
hosted by Bunderhost: the pages and the viewer are the Worker's static assets, the Worker
answers `/api/*`.

| Path | |
| --- | --- |
| `pages/index.html`, `pages/landing.css`, `pages/landing.js`, `pages/img/landing/` | the landing page, written by hand after `designs/agentic-design-site.pen` (dark only): the screenshots are of the real app (0.6.4) at work, the "Watch them work" scene is live HTML |
| `pages/download/index.html`, `pages/download.js` | the download page (`/download`, with the landing's look): a tab per system, the visitor's first (or `#mac`, `#windows`, `#linux`); each button gets its file from the newest GitHub release that has one, by the names the release workflow gives them |
| `pages/styles.css`, `pages/main.js` | shared by the other pages (sign-in, My files, account, 404): tokens, light and dark, the theme button, the download link |
| `pages/fonts/` | Inter and JetBrains Mono, Latin subsets as woff2 (`tools/fonts.py` writes them from `designs/sample/fonts`; OFL) |
| `pages/favicon.*`, `pages/img/apple-touch-icon.png`, `pages/img/icon-*.png`, `pages/img/logo-*.png` | the app icon's web set (from the Dogfooder's final icon set): the favicons from the small-size master (the SVG switches light and dark with the system), the touch and manifest icons, and the logo in the nav and footer (32 px from the small master, 64 and 96 px from the 1024 one, light and dark) |
| `pages/img/og.png` | the Open Graph card: the app icon on cream, 1200 × 630, from the icon set |
| `build.mjs` | `node build.mjs` → `dist/client`: the pages with hashed asset names and the stylesheet inlined, the viewer from `../build/web` under `/view` with the sample design, and `_headers` (hashed names are immutable). Plain files that any static host can serve |
| `scripts/viewer.sh` | builds the viewer (`../tools/build_web.sh`); where Odin or `wasm-ld` are missing (Bunderhost's build image) it fetches the pinned Odin release and installs `lld` |
| `src/workerstack.ts`, `src/schema.ts` | the backend: accounts (Better Auth, personal workspaces with a plan), shared files and links under `/api` ([docs/cloud-design.md](../docs/cloud-design.md)) |
| `src/server.ts` | the Worker entry: share pages (`/s/:token`, `/embed/:token`), a shared version's files (`/c/…`), uploads through the Worker (`/api/blobs/…`), then the backend, else 404 |
| `src/files.ts`, `src/share.ts`, `src/blobs.ts`, `src/plans.ts`, `src/workspaces.ts`, `src/crypto.ts`, `src/zip.ts` | uploads and links; what a link opens; content-addressed blobs; plans and entitlements; workspaces; tokens and tickets; the download zip |
| `src/server.ts`, `vite.config.ts` | the Worker: Cloudflare serves every file of `dist/client` itself; a request no file matches reaches the Worker, which sends `/api/*` to the backend and answers anything else with `404.html` and status 404. The blueprint says `render: ssr` for that (no SPA fallback to the landing page), so Vite builds the Worker with the Cloudflare plugin directly |
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
"Download" in the nav goes to `/download`; "Download for macOS" goes to the latest release (the page swaps in the dmg's own URL from
the GitHub API when it loads), "Source" to the repository, "Docs" to `docs/`.
