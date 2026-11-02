import { cloudflare } from '@cloudflare/vite-plugin'
import { defineConfig } from 'vite'

// Builds the Worker (src/server.ts, the entry the blueprint names) into dist/server. The
// pages and the viewer are not built by Vite: build.mjs writes them into dist/client, the
// Worker's assets, after this build. (Not workerstack()'s plugin: with render "ssr", which
// sends paths without a file to the Worker so it can answer 404, that plugin expects
// TanStack Start.)
export default defineConfig({
	environments: {
		client: { build: { outDir: 'dist/client' } },
		ssr: { build: { outDir: 'dist/server' } },
	},
	plugins: [cloudflare({ viteEnvironment: { name: 'ssr' } })],
})
