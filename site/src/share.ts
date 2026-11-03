// What a share link opens (docs/cloud-design.md §4): the public JSON of a link, the files of
// a version under /c/<token>/<versionId>/ (and the owner's own under
// /api/docs/<id>/v/<versionId>/), the pages /s/<token> and /embed/<token> built from the
// site's templates, and oEmbed.
//
// A version's files are laid out as on disk, relative to its .pen, so the viewer resolves
// them as it does for ?file=. A document that reaches above its folder ("../shared/x.png")
// is placed that many folders deeper ("_/_/doc.pen"), so those paths stay inside the
// version's prefix.
import { and, eq, isNull, sql } from 'drizzle-orm'

import { blobKey, bucket, cors, appUrl, type App } from './blobs'
import { sha256Hex } from './crypto'
import type { Manifest } from './files'
import { document, member, organization, shareLink, user, version } from './schema'
import { zip } from './zip'

export type Resolved = {
	doc: typeof document.$inferSelect
	link: typeof shareLink.$inferSelect | null
	owner: string
}

export type LinkError = 'NOT_FOUND' | 'REVOKED' | 'EXPIRED'

/** A link by its token, if it may be opened now. */
export async function resolveToken(app: App, token: string): Promise<Resolved | LinkError> {
	if (!/^[0-9A-Za-z]{22}$/.test(token)) return 'NOT_FOUND'
	const [row] = await app.db
		.select({ link: shareLink, doc: document, owner: user.name })
		.from(shareLink)
		.innerJoin(document, eq(document.id, shareLink.docId))
		.innerJoin(user, eq(user.id, document.createdBy))
		.where(eq(shareLink.tokenHash, await sha256Hex(token)))
		.limit(1)
	if (!row) return 'NOT_FOUND'
	if (row.link.revokedAt || row.doc.deletedAt) return 'REVOKED'
	if (row.link.expiresAt && row.link.expiresAt.getTime() <= Date.now()) return 'EXPIRED'
	if (!row.doc.headVersionId) return 'NOT_FOUND'
	return { doc: row.doc, link: row.link, owner: row.owner }
}

export async function manifestOf(app: App, docId: string, versionId: string): Promise<Manifest | null> {
	const [ver] = await app.db
		.select({ manifest: version.manifest })
		.from(version)
		.where(and(eq(version.id, versionId), eq(version.docId, docId), eq(version.status, 'committed')))
		.limit(1)
	return ver ? (JSON.parse(ver.manifest) as Manifest) : null
}

/** Resolve "." and ".." in a relative path; leading ".." stay. */
export function normalize(path: string): string {
	const out: string[] = []
	for (const part of path.split('/')) {
		if (part === '' || part === '.') continue
		if (part === '..' && out.length && out[out.length - 1] !== '..') out.pop()
		else out.push(part)
	}
	return out.join('/')
}

/** How many folders a document reaches above its own. */
export function depthOf(m: Manifest): number {
	let depth = 0
	for (const a of [...m.assets.map((x) => x.path), ...m.missing]) {
		let n = 0
		for (const part of normalize(a).split('/')) {
			if (part !== '..') break
			n++
		}
		depth = Math.max(depth, n)
	}
	return depth
}

export const docPath = (m: Manifest) => `${'_/'.repeat(depthOf(m))}doc.pen`

/** The blob a path under a version's prefix names, or null. */
export function lookup(m: Manifest, rel: string): { hash: string; type: string } | null {
	const dir = '_/'.repeat(depthOf(m))
	if (rel === `${dir}doc.pen`) return { hash: m.pen.hash, type: 'application/json' }
	if (rel === '_ad/og.png') return m.previews.og ? { hash: m.previews.og.hash, type: 'image/png' } : null
	if (rel.startsWith('_ad/frames/') && rel.endsWith('.png')) {
		const id = rel.slice('_ad/frames/'.length, -'.png'.length)
		const f = (m.previews.frames ?? []).find((x) => x.id === id)
		return f ? { hash: f.hash, type: 'image/png' } : null
	}
	const want = normalize(rel)
	for (const a of m.assets) if (normalize(dir + a.path) === want) return { hash: a.hash, type: a.type }
	return null
}

export function shareJson(app: App, r: Resolved, token: string, m: Manifest, request?: Request) {
	const base = `/c/${token}/${r.doc.headVersionId}`
	return {
		name: r.doc.name,
		owner: { name: r.owner },
		version: { id: r.doc.headVersionId, createdAt: r.doc.updatedAt.toISOString() },
		doc: { url: `${base}/${docPath(m)}` },
		allowDownload: r.link!.allowDownload,
		allowEmbed: r.link!.allowEmbed,
		visibility: r.link!.visibility,
		previews: {
			og: m.previews.og ? `${base}/_ad/og.png` : null,
			frames: (m.previews.frames ?? []).map((f) => ({
				id: f.id,
				name: f.name,
				width: f.width,
				height: f.height,
				url: `${base}/_ad/frames/${encodeURIComponent(f.id)}.png`,
			})),
		},
		missing: m.missing,
		download: r.link!.allowDownload ? `${base}/_ad/download.zip` : null,
		url: `${appUrl(app, request)}/s/${token}`,
	}
}

export async function countView(app: App, linkId: string) {
	await app.db
		.update(shareLink)
		.set({ viewCount: sql`${shareLink.viewCount} + 1` })
		.where(eq(shareLink.id, linkId))
}

// ---------------------------------------------------------------- files of a version

// Every user file: never sniffed, never framed, no script when opened directly (decision 5).
const SECURITY = {
	'x-content-type-options': 'nosniff',
	'referrer-policy': 'no-referrer',
	'cross-origin-resource-policy': 'same-site',
	'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; sandbox",
}

function plain(status: number, text: string, extra: Record<string, string> = {}) {
	return new Response(text, { status, headers: { 'content-type': 'text/plain; charset=utf-8', ...SECURITY, ...extra } })
}

async function serveBlob(app: App, request: Request, workspaceId: string, m: Manifest, rel: string, name: string) {
	if (rel === '_ad/download.zip') {
		const files = [{ path: `${name}/${docPath(m).replace(/^(_\/)+/, '')}`, hash: m.pen.hash }]
		const dir = '_/'.repeat(depthOf(m))
		for (const a of m.assets) files.push({ path: `${name}/${normalize(dir + a.path).replace(/^(_\/)+/, '')}`, hash: a.hash })
		const store = bucket(app)
		const body = zip(files, async (hash) => {
			const res = await store.get(blobKey(workspaceId, hash))
			return new Uint8Array(await res.arrayBuffer())
		})
		return new Response(body, {
			headers: {
				'content-type': 'application/zip',
				'content-disposition': `attachment; filename="${encodeURIComponent(name)}.zip"`,
				'cache-control': 'private, no-store',
				...SECURITY,
			},
		})
	}
	const hit = lookup(m, rel)
	if (!hit) return plain(404, 'Not found', cors(app))
	const res = await bucket(app).get(blobKey(workspaceId, hit.hash))
	if (!res.ok) return plain(404, 'Not found', cors(app))
	const headers: Record<string, string> = {
		'content-type': hit.type === 'application/json' ? 'application/json; charset=utf-8' : hit.type,
		'cache-control': 'private, max-age=31536000, immutable',
		etag: `"${hit.hash}"`,
		...SECURITY,
		...cors(app),
	}
	if (request.headers.get('if-none-match') === `"${hit.hash}"`) return new Response(null, { status: 304, headers })
	return new Response(request.method === 'HEAD' ? null : res.body, { headers })
}

/** GET /c/<token>/<versionId>/<path>: a shared version's files, for anyone with the link. */
export async function handleContent(app: App, request: Request): Promise<Response> {
	if (request.method !== 'GET' && request.method !== 'HEAD') return plain(405, 'Method not allowed')
	const [, , token, versionId, ...rest] = new URL(request.url).pathname.split('/')
	const r = await resolveToken(app, token ?? '')
	if (typeof r === 'string') return plain(r === 'NOT_FOUND' ? 404 : 410, r, cors(app))
	const m = await manifestOf(app, r.doc.id, versionId ?? '')
	if (!m) return plain(404, 'NOT_FOUND', cors(app))
	const rel = rest.map(decodeURIComponent).join('/')
	if (rel === '_ad/download.zip' && !r.link!.allowDownload) return plain(403, 'Downloads are off for this link')
	return serveBlob(app, request, r.doc.workspaceId, m, rel, r.doc.name)
}

/** GET /api/docs/<docId>/v/<versionId>/<path>: the owner's own files, with the session. */
export async function handleOwnerContent(app: App & { auth: any }, request: Request): Promise<Response> {
	if (request.method !== 'GET' && request.method !== 'HEAD') return plain(405, 'Method not allowed')
	const session = await app.auth.api.getSession({ headers: request.headers }).catch(() => null)
	if (!session?.user) return plain(401, 'Sign in')
	const [, , , docId, , versionId, ...rest] = new URL(request.url).pathname.split('/')
	const [row] = await app.db
		.select({ doc: document })
		.from(document)
		.innerJoin(organization, eq(organization.id, document.workspaceId))
		.where(and(eq(document.id, docId ?? ''), isNull(document.deletedAt)))
		.limit(1)
	if (!row || !(await isMember(app, session.user.id, row.doc.workspaceId))) return plain(404, 'NOT_FOUND')
	const m = await manifestOf(app, row.doc.id, versionId ?? '')
	if (!m) return plain(404, 'NOT_FOUND')
	return serveBlob(app, request, row.doc.workspaceId, m, rest.map(decodeURIComponent).join('/'), row.doc.name)
}

async function isMember(app: App, userId: string, workspaceId: string) {
	const found = await app.db
		.select({ id: member.id })
		.from(member)
		.where(and(eq(member.userId, userId), eq(member.organizationId, workspaceId)))
		.limit(1)
	return Boolean(found[0])
}

// ---------------------------------------------------------------- pages

const esc = (s: string) =>
	s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

const FALLBACK = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><!--ad:head--></head><body><script>
const d = JSON.parse(document.getElementById('ad-share').textContent);
if (d.doc) location.replace('/view/?file=' + encodeURIComponent(d.doc.url));
else document.body.textContent = d.error === 'NOT_FOUND' ? 'This link does not exist.' : 'This link no longer works.';
</script></body></html>`

type Assets = { fetch(input: Request | string | URL): Promise<Response> } | undefined

/** /s/<token> and /embed/<token>: the site's template with the link's data and tags. */
export async function handlePage(app: App, request: Request, assets: Assets, kind: 's' | 'embed'): Promise<Response> {
	const url = new URL(request.url)
	const token = url.pathname.split('/')[2] ?? ''
	const site = appUrl(app, request)
	let template = FALLBACK
	if (assets) {
		const t = await assets.fetch(new URL(kind === 's' ? '/_share.html' : '/_embed.html', url))
		if (t.ok) template = await t.text()
	}
	const r = await resolveToken(app, token)
	let data: object
	let head: string[]
	let status = 200
	let embeddable = false
	if (typeof r === 'string') {
		status = r === 'NOT_FOUND' ? 404 : 410
		data = { error: r }
		head = [`<title>Agentic Design</title>`, `<meta name="robots" content="noindex">`]
	} else {
		const m = (await manifestOf(app, r.doc.id, r.doc.headVersionId!))!
		const share = shareJson(app, r, token, m, request)
		data = share
		embeddable = kind === 'embed' && r.link!.allowEmbed
		if (kind === 'embed' && !embeddable) {
			status = 403
			data = { error: 'EMBED_OFF' }
		}
		await countView(app, r.link!.id)
		const title = `${r.doc.name} · Agentic Design`
		const image = share.previews.og ? `${site}${share.previews.og}` : `${site}/img/og.png`
		head = [
			`<title>${esc(title)}</title>`,
			`<meta property="og:type" content="website">`,
			`<meta property="og:title" content="${esc(r.doc.name)}">`,
			`<meta property="og:description" content="${esc(`A design by ${r.owner}, shared with Agentic Design`)}">`,
			`<meta property="og:url" content="${esc(share.url)}">`,
			`<meta property="og:image" content="${esc(image)}">`,
			`<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">`,
			`<meta name="twitter:card" content="summary_large_image">`,
			`<meta name="twitter:image" content="${esc(image)}">`,
			r.link!.visibility === 'public' ? '' : `<meta name="robots" content="noindex">`,
			r.link!.allowEmbed
				? `<link rel="alternate" type="application/json+oembed" href="${esc(`${site}/api/oembed?url=${encodeURIComponent(share.url)}`)}">`
				: '',
		]
	}
	head.push(`<meta name="referrer" content="no-referrer">`)
	const json = JSON.stringify(data).replace(/</g, '\\u003c')
	head.push(`<script type="application/json" id="ad-share">${json}</script>`)
	const html = template.replace('<!--ad:head-->', head.filter(Boolean).join('\n'))
	const headers: Record<string, string> = {
		'content-type': 'text/html; charset=utf-8',
		'cache-control': 'private, no-store',
		'referrer-policy': 'no-referrer',
		'x-content-type-options': 'nosniff',
		'content-security-policy': embeddable ? 'frame-ancestors *' : "frame-ancestors 'self'",
	}
	if (typeof r !== 'string' && r.link!.visibility !== 'public') headers['x-robots-tag'] = 'noindex'
	return new Response(request.method === 'HEAD' ? null : html, { status, headers })
}

/** The token of a share URL on this site, or null. */
export function tokenOfShareUrl(app: App, text: string, request?: Request): string | null {
	try {
		const u = new URL(text)
		if (u.origin !== new URL(appUrl(app, request) || u.origin).origin) return null
		const m = /^\/(?:s|embed)\/([0-9A-Za-z]{22})\/?$/.exec(u.pathname)
		return m ? m[1]! : null
	} catch {
		return null
	}
}
