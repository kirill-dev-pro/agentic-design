// Sign-in for the Mac app (docs/cloud-design.md §3.1, §6.1): the app never shows a password
// field. It opens the system browser at /auth/app with a PKCE challenge and a loopback port;
// the signed-in user approves this device; the browser is sent to
// http://127.0.0.1:<port>/callback with a one-time code; the app trades the code and its
// verifier for a device session token, which it sends as `Authorization: Bearer <token>`.
// A device is a Better Auth session, so it is listed and revoked with the others
// (list-sessions, revoke-session).
import { and, eq, gt, isNull } from 'drizzle-orm'

import { appUrl, type App } from './blobs'
import { randomToken, sha256Hex } from './crypto'
import { appAuthCode } from './schema'

const CODE_SECONDS = 120

type Params = { challenge: string; port: number; state: string; device: string }

function params(url: URL): Params | null {
	const challenge = url.searchParams.get('challenge') ?? ''
	const port = Number(url.searchParams.get('port'))
	const state = url.searchParams.get('state') ?? ''
	const device = (url.searchParams.get('device') ?? 'Mac').replace(/[\u0000-\u001f]/g, '').slice(0, 80) || 'Mac'
	if (!/^[A-Za-z0-9_-]{43}$/.test(challenge)) return null
	if (!Number.isInteger(port) || port < 1024 || port > 65535) return null
	if (!/^[A-Za-z0-9_-]{16,128}$/.test(state)) return null
	return { challenge, port, state, device }
}

const esc = (s: string) =>
	s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

function page(status: number, body: string) {
	const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign in to Agentic Design</title><meta name="robots" content="noindex"><style>body{font:16px/1.5 system-ui,sans-serif;max-width:28rem;margin:15vh auto;padding:0 1.5rem;color:#1a1a1b}@media(prefers-color-scheme:dark){body{background:#1a1a1b;color:#eee}}button{font:inherit;padding:.6rem 1.2rem;border-radius:.5rem;border:0;background:#c96442;color:#fff;cursor:pointer}a{color:inherit}</style></head><body>${body}</body></html>`
	return new Response(html, {
		status,
		headers: {
			'content-type': 'text/html; charset=utf-8',
			'cache-control': 'no-store',
			'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' http://127.0.0.1:*; frame-ancestors 'none'",
			// same-origin, not no-referrer: under no-referrer the browser sends `Origin: null` on
			// the Allow form's POST, which the check below must refuse. The redirect to the
			// loopback is cross-origin, so it still carries no Referer.
			'referrer-policy': 'same-origin',
			'x-content-type-options': 'nosniff',
		},
	})
}

/** A POST from a page of this site: its Origin, or, where a browser sends `null` or none,
 *  Fetch Metadata's Sec-Fetch-Site. A request with neither is refused. */
export function sameOriginPost(request: Request, site: string): boolean {
	const origin = request.headers.get('origin')
	if (origin && origin !== 'null') return origin === site
	return request.headers.get('sec-fetch-site') === 'same-origin'
}

type AuthApp = App & { auth: { api: { getSession(o: { headers: Headers }): Promise<any> } } }

/** GET /auth/app: sign in first if needed, then ask to approve this device.
 *  POST /auth/app: the approval; redirects to the app's loopback with a code. */
export async function handleAppAuth(app: AuthApp, request: Request): Promise<Response> {
	const url = new URL(request.url)
	const p = params(url)
	if (!p) return page(400, '<h1>This sign-in link is not valid</h1><p>Start again from the app.</p>')
	const session = await app.auth.api.getSession({ headers: request.headers }).catch(() => null)
	if (!session?.user) {
		const next = url.pathname + url.search
		return new Response(null, { status: 302, headers: { location: `/signin?next=${encodeURIComponent(next)}`, 'cache-control': 'no-store' } })
	}
	if (request.method === 'GET') {
		return page(
			200,
			`<h1>Sign in to Agentic Design on “${esc(p.device)}”?</h1>
<p>The app will open your shared files and share new ones as <b>${esc(session.user.email)}</b>. You can sign it out any time from your account page.</p>
<form method="post"><button type="submit">Allow</button> &nbsp; <a href="/account">Cancel</a></form>
<p><small>Only allow this if you just chose “Sign in” in the app yourself.</small></p>`,
		)
	}
	if (request.method !== 'POST') return page(405, '<h1>Not allowed</h1>')
	// A form post from this site only (SameSite=Lax keeps cookies off cross-site posts too).
	if (!sameOriginPost(request, new URL(appUrl(app, request)).origin)) return page(403, '<h1>Not allowed</h1>')
	const code = randomToken()
	await app.db.insert(appAuthCode).values({
		codeHash: await sha256Hex(code),
		userId: session.user.id,
		challenge: p.challenge,
		device: p.device,
		expiresAt: new Date(Date.now() + CODE_SECONDS * 1000),
		createdAt: new Date(),
	})
	const back = `http://127.0.0.1:${p.port}/callback?code=${code}&state=${encodeURIComponent(p.state)}`
	return new Response(null, { status: 303, headers: { location: back, 'cache-control': 'no-store' } })
}

function b64url(bytes: ArrayBuffer): string {
	let s = ''
	for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b)
	return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

/** The code and the verifier for a device session (once; within two minutes). */
export async function exchangeCode(app: App & { auth: any }, code: string, verifier: string) {
	if (!/^[A-Za-z0-9_-]{43,128}$/.test(verifier) || !/^[0-9A-Za-z]{22}$/.test(code)) return null
	const now = new Date()
	const [row] = await app.db
		.update(appAuthCode)
		.set({ usedAt: now })
		.where(and(eq(appAuthCode.codeHash, await sha256Hex(code)), isNull(appAuthCode.usedAt), gt(appAuthCode.expiresAt, now)))
		.returning()
	if (!row) return null
	const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
	if (challenge !== row.challenge) return null
	const ctx = await app.auth.$context
	const session = await ctx.internalAdapter.createSession(row.userId, false, { userAgent: `Agentic Design for Mac (${row.device})` })
	if (!session) return null
	return { token: session.token as string, expiresAt: new Date(session.expiresAt).toISOString() }
}
