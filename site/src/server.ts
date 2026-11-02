// The site's Worker. Cloudflare serves every file of dist/client itself (the pages, /view,
// /edit); a request reaches this code only when no file matches. /api goes to the
// Workerstack backend; anything else is a page that does not exist, answered with
// 404.html and status 404 (not the landing page: search engines index soft 404s).
import { createWorker } from 'workerstack/workers'

import { backend } from './workerstack'

type Env = { ASSETS: { fetch(input: Request | string | URL): Promise<Response> } }

const worker = createWorker(backend)
export const { Scheduler, RealtimeHub, RateLimiter } = worker.durableObjects

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url)
		if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
			return worker.handler.fetch(request, env as never, ctx)
		}
		const page = await env.ASSETS.fetch(new URL('/404.html', url))
		const headers = new Headers(page.headers)
		headers.set('Cache-Control', 'public, max-age=0, must-revalidate')
		return new Response(request.method === 'HEAD' ? null : page.body, { status: 404, headers })
	},
	scheduled: worker.handler.scheduled,
}
