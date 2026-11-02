import { workerstack } from 'workerstack/vite'
import { defineConfig } from 'vite'

// The Worker: the API under /api (empty for now) in front of static assets. The pages and
// the viewer are not built by Vite: build.mjs writes them into dist/client, the Worker's
// assets directory, after this build.
export default defineConfig({ plugins: [workerstack()] })
