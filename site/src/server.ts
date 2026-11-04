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
import { createMemoryRateLimitStore, type RateLimitStore } from 'workerstack'
import { durableRateLimitStore, type ExecutionContextLike } from 'workerstack/workers'

import { handleExport } from './account'
import { traced, withAuthTrace } from './auth-trace'
import { handleAppAuth } from './app-auth'
import { handleBlobPut, type App } from './blobs'
import { handleRoom, ROOM_PATH } from './room/route'
import { handleContent, handleOwnerContent, handlePage } from './share'
import { worker } from './worker'

type Env = {
	ASSETS: { fetch(input: Request | string | URL): Promise<Response> }
	RATE_LIMITER?: Parameters<typeof durableRateLimitStore>[0]
	DOC_ROOM?: Parameters<typeof handleRoom>[2]
}

export const { Scheduler, RealtimeHub, RateLimiter } = worker.durableObjects
// Re-exported from its module under its declared name (the bundler renames worker.durableObjects' copies).
export { DocRoom } from './room/doc-room'

const OWNER_FILES = /^\/api\/docs\/[^/]+\/v\/[^/]+\/.+/

// Requests per minute and client for the paths answered outside the backend (whose own
// limit covers /api). A page view is one request; opening a document fetches its files.
const LIMITS = { page: 120, content: 1200, upload: 600 } as const
let memoryLimits: RateLimitStore | undefined

async function limited(env: Env, request: Request, kind: keyof typeof LIMITS): Promise<Response | null> {
	const store = env.RATE_LIMITER ? durableRateLimitStore(env.RATE_LIMITER) : (memoryLimits ??= createMemoryRateLimitStore())
	const ip = request.headers.get('cf-connecting-ip') ?? 'local'
	const hit = await store.hit(`${ip}:${kind}`, 60_000, LIMITS[kind])
	if (hit.allowed) return null
	const retry = Math.max(1, Math.ceil((hit.resetAt - Date.now()) / 1000))
	return new Response('Too many requests', { status: 429, headers: { 'retry-after': String(retry), 'content-type': 'text/plain' } })
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContextLike): Promise<Response> {
		const url = new URL(request.url)
		const path = url.pathname
		const own = (kind: keyof typeof LIMITS, run: (app: App & { auth: unknown }) => Promise<Response>) =>
			worker.withContext(ctx, async () => (await limited(env, request, kind)) ?? run((await worker.app(env as never)) as never))
		if (/^\/(s|embed)\/[^/]+\/?$/.test(path))
			return own('page', (app) => handlePage(app, request, env.ASSETS, path.startsWith('/s/') ? 's' : 'embed'))
		if (path === '/api/account/export') return own('content', (app) => handleExport(app as never, request))
		if (path === '/auth/app') return own('page', (app) => handleAppAuth(app as never, request))
		if (path.startsWith('/c/')) return own('content', (app) => handleContent(app, request))
		if (path.startsWith('/api/blobs/')) return own('upload', (app) => handleBlobPut(app, request))
		const room = ROOM_PATH.exec(path)
		if (room) return own('page', (app) => handleRoom(app as never, request, env.DOC_ROOM, decodeURIComponent(room[1]!)))
		if (OWNER_FILES.test(path)) return own('content', (app) => handleOwnerContent(app, request))
		if (traced(path))
			return worker.withContext(ctx, async () =>
				withAuthTrace((await worker.app(env as never)) as never, request, (r) => worker.handler.fetch(r, env as never, ctx)),
			)
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
