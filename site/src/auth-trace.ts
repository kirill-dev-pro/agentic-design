// A short trace of Google/GitHub sign-ins (managed identity): what the page asked for when it
// started one, and where the OAuth callback sent the browser. It exists to find why a sign-in
// ends on the home page; it records no tokens, codes, state values, cookies, emails or IPs.
// Rows older than 7 days go with the nightly cleanup.
import { lt } from 'drizzle-orm'

import type { App } from './blobs'
import { authTrace } from './schema'

const START = '/api/auth/managed/sign-in'
const CALLBACK = /^\/api\/auth\/callback\/[^/]+$/

export const traced = (path: string) => path === START || CALLBACK.test(path)

/** A URL without its query values: the path, and the names of its parameters (error kept). */
function shape(location: string | null, origin: string): string | null {
	if (!location) return null
	try {
		const u = new URL(location, origin)
		const names: string[] = []
		u.searchParams.forEach((_v, k) => {
			if (!names.includes(k)) names.push(k)
		})
		const keys = names.map((k) => (k === 'error' ? `error=${u.searchParams.get('error')}` : k))
		return `${u.origin === origin ? '' : u.origin}${u.pathname}${keys.length ? `?${keys.join('&')}` : ''}`
	} catch {
		return '(unparsable)'
	}
}

/** Run the request, and note what it started or where it ended. Never fails the request. */
export async function withAuthTrace(app: Pick<App, 'db'>, request: Request, run: (r: Request) => Promise<Response>) {
	const url = new URL(request.url)
	let asked: string | null = null
	let provider: string | null = null
	if (url.pathname === START && request.method === 'POST') {
		try {
			const body = (await request.clone().json()) as { provider?: unknown; callbackURL?: unknown }
			provider = typeof body.provider === 'string' ? body.provider.slice(0, 32) : null
			asked = typeof body.callbackURL === 'string' ? shape(body.callbackURL, url.origin) : '(none)'
		} catch {
			asked = '(unreadable body)'
		}
	}
	const res = await run(request)
	try {
		let location = res.headers.get('location')
		if (url.pathname === START && res.ok) location = null
		await app.db.insert(authTrace).values({
			at: new Date(),
			step: url.pathname === START ? 'start' : 'callback',
			provider: provider ?? url.pathname.split('/').pop()!.slice(0, 32),
			asked,
			status: res.status,
			location: shape(location, url.origin),
			hadStateCookie: /better-auth\.state=/.test(request.headers.get('cookie') ?? ''),
			hadState: url.searchParams.has('state'),
		})
	} catch (error) {
		console.error('[auth-trace]', String(error))
	}
	return res
}

export async function pruneAuthTrace(app: Pick<App, 'db'>, now = Date.now()) {
	await app.db.delete(authTrace).where(lt(authTrace.at, new Date(now - 7 * 86_400_000)))
}
