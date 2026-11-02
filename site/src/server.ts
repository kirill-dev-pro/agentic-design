// The site's Worker. Cloudflare serves every file of dist/client itself (the pages, /view,
// /edit); a request reaches this code only when no file matches.
//
// - /s/<token> and /embed/<token>: a share link's page, the site's template with the link's
//   data (src/share.ts);
// - /c/<token>/<versionId>/…: the files of a shared version;
// - /api/docs/<id>/v/<versionId>/…: the owner's own files, with the session;
// - /api/blobs/<ticket>: uploads through the Worker when storage has no presigned PUTs;
// - the rest of /api goes to the Workerstack backend;
// - anything else is a page that does not exist, answered with 404.html and status 404
//   (not the landing page: search engines index soft 404s).
import { createWorker, type ExecutionContextLike } from 'workerstack/workers'

import { handleBlobPut, type App } from './blobs'
import { handleContent, handleOwnerContent, handlePage } from './share'
import { backend } from './workerstack'

type Env = { ASSETS: { fetch(input: Request | string | URL): Promise<Response> } }

const worker = createWorker(backend)
export const { Scheduler, RealtimeHub, RateLimiter } = worker.durableObjects

const OWNER_FILES = /^\/api\/docs\/[^/]+\/v\/[^/]+\/.+/

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContextLike): Promise<Response> {
		const url = new URL(request.url)
		const path = url.pathname
		const own = (run: (app: App & { auth: unknown }) => Promise<Response>) =>
			worker.withContext(ctx, async () => run((await worker.app(env as never)) as never))
		if (/^\/(s|embed)\/[^/]+\/?$/.test(path)) return own((app) => handlePage(app, request, env.ASSETS, path.startsWith('/s/') ? 's' : 'embed'))
		if (path.startsWith('/c/')) return own((app) => handleContent(app, request))
		if (path.startsWith('/api/blobs/')) return own((app) => handleBlobPut(app, request))
		if (OWNER_FILES.test(path)) return own((app) => handleOwnerContent(app, request))
		if (path === '/api' || path.startsWith('/api/')) {
			return worker.handler.fetch(request, env as never, ctx)
		}
		const page = await env.ASSETS.fetch(new URL('/404.html', url))
		const headers = new Headers(page.headers)
		headers.set('Cache-Control', 'public, max-age=0, must-revalidate')
		return new Response(request.method === 'HEAD' ? null : page.body, { status: 404, headers })
	},
	scheduled: worker.handler.scheduled,
}
